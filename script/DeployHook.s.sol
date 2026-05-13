// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";

/// @title DeployHook
/// @notice 在 Anvil 本地节点上部署完整的 Uniswap v4 + DynamicFeeHook 环境          
contract DeployHook is Script {
    using PoolIdLibrary for PoolKey;

    // Anvil 默认测试账户私钥
    uint256 constant ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // 1:1 初始价格对应的 sqrtPriceX96
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Hook 地址位掩码：beforeSwap | afterSwap
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function run() external {
        address deployer = vm.addr(ANVIL_PRIVATE_KEY);
        vm.startBroadcast(ANVIL_PRIVATE_KEY);

        // ─── 步骤 1：部署 PoolManager ────────────────────────
        PoolManager poolManager = new PoolManager(deployer);
        console.log("PoolManager deployed at:", address(poolManager));

        // ─── 步骤 2：部署测试 ERC20 代币 ─────────────────────
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);

        // 确保 token0 地址 < token1 地址（Uniswap v4 要求）
        MockERC20 token0;
        MockERC20 token1;
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }

        // 铸造代币给部署者
        token0.mint(deployer, 1_000_000 ether);
        token1.mint(deployer, 1_000_000 ether);

        console.log("Token0 deployed at:", address(token0));
        console.log("Token1 deployed at:", address(token1));

        // ─── 步骤 3：使用 vm.etch 部署 DynamicFeeHook ────────
        // 计算满足地址约束的 hook 地址（低位必须匹配 HOOK_FLAGS）
        address hookAddress = address(
            uint160(
                uint256(type(uint160).max) & ~Hooks.ALL_HOOK_MASK | HOOK_FLAGS
            )
        );

        // 部署实现合约，然后将代码 etch 到目标地址
        DynamicFeeHook impl = new DynamicFeeHook(IPoolManager(address(poolManager)));
        vm.etch(hookAddress, address(impl).code);
        DynamicFeeHook hook = DynamicFeeHook(hookAddress);

        console.log("DynamicFeeHook deployed at:", address(hook));

        // ─── 步骤 4：初始化流动性池 ───────────────────────────
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);
        PoolId poolId = poolKey.toId();

        console.log("Pool initialized. PoolId (first 32 bytes):");
        console.logBytes32(PoolId.unwrap(poolId));

        vm.stopBroadcast();

        // ─── 输出部署摘要 ─────────────────────────────────────
        console.log("\n=== Deployment Summary ===");
        console.log("Deployer:      ", deployer);
        console.log("PoolManager:   ", address(poolManager));
        console.log("DynamicFeeHook:", address(hook));
        console.log("Token0:        ", address(token0));
        console.log("Token1:        ", address(token1));
        console.log("HIGH_FEE (1%):", hook.HIGH_FEE());
        console.log("MID_FEE (0.3%):", hook.MID_FEE());
        console.log("LOW_FEE (0.05%):", hook.LOW_FEE());
        console.log("LOW_VOLUME_THRESHOLD:", hook.LOW_VOLUME_THRESHOLD());
        console.log("HIGH_VOLUME_THRESHOLD:", hook.HIGH_VOLUME_THRESHOLD());
        console.log("TIME_WINDOW (seconds):", hook.TIME_WINDOW());
    }
}
