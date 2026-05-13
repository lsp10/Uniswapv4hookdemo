// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title DynamicFeeHook
/// @notice Uniswap v4 Hook，根据滚动时间窗口内的累计交易量动态调整手续费
/// @dev 交易量越高费率越低（激励流动性），交易量越低费率越高（保护流动性提供者）
contract DynamicFeeHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // ─── 错误 ────────────────────────────────────────────────
    error NotPoolManager();

    // ─── 常量 ────────────────────────────────────────────────
    /// @notice 高费率：1%（低交易量时保护 LP）
    uint24 public constant HIGH_FEE = 10000;
    /// @notice 中费率：0.3%（标准交易量）
    uint24 public constant MID_FEE = 3000;
    /// @notice 低费率：0.05%（高交易量时激励交易）
    uint24 public constant LOW_FEE = 500;

    /// @notice 低/中量分界线：10 ETH
    uint256 public constant LOW_VOLUME_THRESHOLD = 10 ether;
    /// @notice 中/高量分界线：100 ETH
    uint256 public constant HIGH_VOLUME_THRESHOLD = 100 ether;
    /// @notice 滚动时间窗口：1 小时
    uint256 public constant TIME_WINDOW = 3600;

    // ─── 状态 ────────────────────────────────────────────────
    /// @notice Uniswap v4 PoolManager 合约地址
    IPoolManager public immutable poolManager;

    /// @notice 每个池的交易量数据
    struct PoolVolumeData {
        uint256 cumulativeVolume;   // 当前时间窗口内累计交易量（wei）
        uint256 lastResetTimestamp; // 上次重置时间戳（Unix 秒）
    }

    mapping(PoolId => PoolVolumeData) public poolVolumes;

    // ─── 事件 ────────────────────────────────────────────────
    /// @notice 每次 swap 后更新交易量时触发
    event VolumeUpdated(
        PoolId indexed poolId,
        uint256 newVolume,
        uint24  currentFee
    );

    // ─── 修饰符 ──────────────────────────────────────────────
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ─── 构造函数 ────────────────────────────────────────────
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ─── Hook 权限声明 ───────────────────────────────────────
    /// @notice 声明本 Hook 需要的权限：仅 beforeSwap 和 afterSwap
    /// @dev Uniswap v4 通过合约地址低位验证权限，部署时需使用 vm.etch 或 CREATE2 确保地址匹配
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Hook 回调实现 ───────────────────────────────────────

    /// @notice swap 前回调：检查时间窗口是否过期，计算并返回动态费率
    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        // 检查时间窗口是否过期，过期则重置交易量
        _maybeResetVolume(poolId);

        // 根据当前累计交易量计算费率，并附加 OVERRIDE_FEE_FLAG 以覆盖池的默认费率
        uint24 fee = _computeFee(poolVolumes[poolId].cumulativeVolume) | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    /// @notice swap 后回调：累加本次交易量，发出事件
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // 计算本次交易量（取 amountSpecified 的绝对值）
        uint256 volume = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // 累加到当前时间窗口
        poolVolumes[poolId].cumulativeVolume += volume;

        // 计算更新后的费率（用于事件，不含 OVERRIDE_FEE_FLAG）
        uint24 currentFee = _computeFee(poolVolumes[poolId].cumulativeVolume);

        emit VolumeUpdated(poolId, poolVolumes[poolId].cumulativeVolume, currentFee);

        return (IHooks.afterSwap.selector, 0);
    }

    // ─── 未使用的 Hook 回调（返回选择器以满足接口要求）────────

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ─── 内部辅助函数 ────────────────────────────────────────

    /// @notice 根据累计交易量计算三档费率
    /// @param volume 当前时间窗口内的累计交易量
    /// @return fee 对应的手续费率（pips）
    function _computeFee(uint256 volume) internal pure returns (uint24 fee) {
        if (volume < LOW_VOLUME_THRESHOLD) {
            return HIGH_FEE;  // 1%
        } else if (volume < HIGH_VOLUME_THRESHOLD) {
            return MID_FEE;   // 0.3%
        } else {
            return LOW_FEE;   // 0.05%
        }
    }

    /// @notice 公开版本的费率计算函数，供测试使用
    function _computeFeePublic(uint256 volume) external pure returns (uint24) {
        return _computeFee(volume);
    }

    /// @notice 检查时间窗口是否过期，过期则重置交易量累计器
    /// @param poolId 目标池的 ID
    function _maybeResetVolume(PoolId poolId) internal {
        PoolVolumeData storage data = poolVolumes[poolId];
        if (block.timestamp > data.lastResetTimestamp + TIME_WINDOW) {
            data.cumulativeVolume = 0;
            data.lastResetTimestamp = block.timestamp;
        }
    }
}
