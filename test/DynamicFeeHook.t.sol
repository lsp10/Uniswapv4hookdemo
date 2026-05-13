// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";

/// @title DynamicFeeHookTest
/// @notice 测试 DynamicFeeHook 的核心逻辑：动态费率、时间窗口重置、事件、访问控制、代币转账与余额
contract DynamicFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    // ─── 测试状态变量 ────────────────────────────────────────
    DynamicFeeHook public hook;
    PoolKey public poolKey;
    PoolId public poolId;

    // 测试账户
    address public alice;
    address public bob;
    address public charlie;
    address public dave;
    address public eve;

    // ─── 常量 ────────────────────────────────────────────────
    // beforeSwap 和 afterSwap 对应的地址位掩码
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    // ─── setUp ───────────────────────────────────────────────
    function setUp() public {
        // 1. 部署 PoolManager 和所有测试 Router
        deployFreshManagerAndRouters();

        // 2. 使用 vm.etch 将 DynamicFeeHook 部署到满足地址约束的地址
        //    地址低位必须匹配 BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG = 0xC0
        address hookAddress = address(
            uint160(
                uint256(type(uint160).max) & ~Hooks.ALL_HOOK_MASK | HOOK_FLAGS
            )
        );
        DynamicFeeHook impl = new DynamicFeeHook(manager);
        vm.etch(hookAddress, address(impl).code);
        hook = DynamicFeeHook(hookAddress);

        // 3. 部署并铸造测试代币，授权给所有 Router
        deployMintAndApprove2Currencies();

        // 4. 创建并初始化流动性池（使用 DYNAMIC_FEE_FLAG）
        (poolKey, poolId) = initPool(
            currency0,
            currency1,
            IHooks(hookAddress),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // 5. 添加初始流动性（覆盖全范围 tick，支撑大额 swap 测试）
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10_000e18,
                salt: 0
            }),
            ZERO_BYTES
        );

        // 6. 创建测试账户
        alice   = makeAddr("alice");
        bob     = makeAddr("bob");
        charlie = makeAddr("charlie");
        dave    = makeAddr("dave");
        eve     = makeAddr("eve");
    }

    // ═══════════════════════════════════════════════════════════
    // 费率档位测试
    // ═══════════════════════════════════════════════════════════

    /// @notice 低交易量（< 10 ETH）时应返回高费率 1%
    function test_highFee_lowVolume() public {
        // 执行小额 swap（1 ETH，远低于 LOW_VOLUME_THRESHOLD = 10 ETH）
        swap(poolKey, true, -1 ether, ZERO_BYTES);

        // 验证累计交易量
        (uint256 vol,) = hook.poolVolumes(poolId);
        assertEq(vol, 1 ether, "volume should be 1 ether");

        // 验证费率仍为 HIGH_FEE（因为 1 ether < 10 ether）
        uint24 expectedFee = hook.HIGH_FEE();
        assertEq(hook._computeFeePublic(vol), expectedFee, "fee should be HIGH_FEE");
    }

    /// @notice 中等交易量（10–100 ETH）时应返回中费率 0.3%
    function test_midFee_midVolume() public {
        // 执行 50 ETH swap，使累计量落在 [10, 100) 区间
        swap(poolKey, true, -50 ether, ZERO_BYTES);

        (uint256 vol,) = hook.poolVolumes(poolId);
        assertGe(vol, hook.LOW_VOLUME_THRESHOLD(), "volume should be >= LOW_VOLUME_THRESHOLD");
        assertLt(vol, hook.HIGH_VOLUME_THRESHOLD(), "volume should be < HIGH_VOLUME_THRESHOLD");

        uint24 expectedFee = hook.MID_FEE();
        assertEq(hook._computeFeePublic(vol), expectedFee, "fee should be MID_FEE");
    }

    /// @notice 高交易量（>= 100 ETH）时应返回低费率 0.05%
    function test_lowFee_highVolume() public {
        // 执行 150 ETH swap，使累计量超过 HIGH_VOLUME_THRESHOLD
        swap(poolKey, true, -150 ether, ZERO_BYTES);

        (uint256 vol,) = hook.poolVolumes(poolId);
        assertGe(vol, hook.HIGH_VOLUME_THRESHOLD(), "volume should be >= HIGH_VOLUME_THRESHOLD");

        uint24 expectedFee = hook.LOW_FEE();
        assertEq(hook._computeFeePublic(vol), expectedFee, "fee should be LOW_FEE");
    }

    // ═══════════════════════════════════════════════════════════
    // 时间窗口重置测试
    // ═══════════════════════════════════════════════════════════

    /// @notice 时间窗口过期后，交易量应重置为零，费率恢复为 HIGH_FEE
    function test_volumeReset_afterTimeWindow() public {
        // 先累积到中等档位
        swap(poolKey, true, -50 ether, ZERO_BYTES);
        (uint256 volBefore,) = hook.poolVolumes(poolId);
        assertGe(volBefore, hook.LOW_VOLUME_THRESHOLD(), "should be in mid tier before reset");

        // 推进时间超过 TIME_WINDOW（3600 秒）
        vm.warp(block.timestamp + hook.TIME_WINDOW() + 1);

        // 执行新的小额 swap，触发时间窗口重置
        swap(poolKey, true, -1 ether, ZERO_BYTES);

        // 验证交易量已重置（仅含本次 swap 量）
        (uint256 volAfter,) = hook.poolVolumes(poolId);
        assertEq(volAfter, 1 ether, "volume should be reset to just this swap's amount");

        // 验证费率恢复为 HIGH_FEE
        assertEq(hook._computeFeePublic(volAfter), hook.HIGH_FEE(), "fee should be HIGH_FEE after reset");
    }

    // ═══════════════════════════════════════════════════════════
    // VolumeUpdated 事件测试
    // ═══════════════════════════════════════════════════════════

    /// @notice afterSwap 应正确发出 VolumeUpdated 事件
    function test_volumeUpdated_event() public {
        uint256 swapAmount = 5 ether;
        uint24 expectedFee = hook.HIGH_FEE(); // 5 ether < 10 ether

        // 设置事件期望：检查 poolId（indexed）和数据字段
        vm.expectEmit(true, false, false, true, address(hook));
        emit DynamicFeeHook.VolumeUpdated(poolId, swapAmount, expectedFee);

        swap(poolKey, true, -int256(swapAmount), ZERO_BYTES);
    }

    // ═══════════════════════════════════════════════════════════
    // 访问控制测试
    // ═══════════════════════════════════════════════════════════

    /// @notice 非 PoolManager 地址调用 beforeSwap 应回滚
    function test_revert_notPoolManager() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DynamicFeeHook.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ZERO_BYTES
        );
    }

    /// @notice 非 PoolManager 地址调用 afterSwap 应回滚
    function test_revert_notPoolManager_afterSwap() public {
        vm.prank(address(0xdead));
        vm.expectRevert(DynamicFeeHook.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            BalanceDelta.wrap(0),
            ZERO_BYTES
        );
    }

    // ═══════════════════════════════════════════════════════════
    // 代币转账测试（任务 5.9）
    // ═══════════════════════════════════════════════════════════

    /// @notice 测试账户间代币转账：alice 转给 bob，余额正确变化，总供应量不变
    function test_tokenTransfer_betweenAccounts() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));

        // 为 alice 铸造 100 ether 的 token0
        token0.mint(alice, 100 ether);

        uint256 totalSupplyBefore = token0.totalSupply();
        uint256 aliceBalanceBefore = token0.balanceOf(alice);
        uint256 bobBalanceBefore   = token0.balanceOf(bob);

        // alice 转账 10 ether 给 bob
        vm.prank(alice);
        token0.transfer(bob, 10 ether);

        // 验证余额变化
        assertEq(token0.balanceOf(alice), aliceBalanceBefore - 10 ether, "alice balance should decrease by 10 ether");
        assertEq(token0.balanceOf(bob),   bobBalanceBefore + 10 ether,   "bob balance should increase by 10 ether");

        // 验证总供应量不变
        assertEq(token0.totalSupply(), totalSupplyBefore, "total supply should not change");
    }

    /// @notice 余额不足时转账应回滚
    function test_tokenTransfer_insufficientBalance_reverts() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));

        // charlie 余额为零，尝试转账应失败
        assertEq(token0.balanceOf(charlie), 0, "charlie should have zero balance");

        vm.prank(charlie);
        vm.expectRevert();
        token0.transfer(bob, 1 ether);
    }

    /// @notice 多次转账后余额累加正确
    function test_tokenTransfer_multipleTransfers() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        // 为 alice 铸造两种代币
        token0.mint(alice, 200 ether);
        token1.mint(alice, 200 ether);

        // alice 分两次转账给 bob
        vm.startPrank(alice);
        token0.transfer(bob, 30 ether);
        token0.transfer(bob, 20 ether);
        vm.stopPrank();

        assertEq(token0.balanceOf(alice), 150 ether, "alice should have 150 ether token0");
        assertEq(token0.balanceOf(bob),   50 ether,  "bob should have 50 ether token0");

        // alice 转账 token1 给 charlie
        vm.prank(alice);
        token1.transfer(charlie, 100 ether);

        assertEq(token1.balanceOf(alice),   100 ether, "alice should have 100 ether token1");
        assertEq(token1.balanceOf(charlie), 100 ether, "charlie should have 100 ether token1");
    }

    // ═══════════════════════════════════════════════════════════
    // 余额查询测试（任务 5.10）
    // ═══════════════════════════════════════════════════════════

    /// @notice 铸造后余额与铸造量一致
    function test_tokenBalance_afterMint() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        uint256 mintAmount0 = 500 ether;
        uint256 mintAmount1 = 300 ether;

        token0.mint(dave, mintAmount0);
        token1.mint(dave, mintAmount1);

        assertEq(token0.balanceOf(dave), mintAmount0, "dave token0 balance should equal mint amount");
        assertEq(token1.balanceOf(dave), mintAmount1, "dave token1 balance should equal mint amount");
    }

    /// @notice swap 后余额变化：token0 减少，token1 增加
    function test_tokenBalance_afterSwap() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        // 记录 swap 前余额（address(this) 是测试合约，已有代币）
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        // 执行 zeroForOne swap（token0 → token1），exactInput 10 ether
        swap(poolKey, true, -10 ether, ZERO_BYTES);

        uint256 balance0After = token0.balanceOf(address(this));
        uint256 balance1After = token1.balanceOf(address(this));

        // token0 应减少（已支出）
        assertLt(balance0After, balance0Before, "token0 balance should decrease after swap");
        // token1 应增加（已收到）
        assertGt(balance1After, balance1Before, "token1 balance should increase after swap");

        console.log("token0 spent:", balance0Before - balance0After);
        console.log("token1 received:", balance1After - balance1Before);
    }

    /// @notice 添加流动性后，账户代币余额减少（代币存入池中）
    function test_tokenBalance_afterLiquidityAdd() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        // 为 eve 铸造代币并授权
        token0.mint(eve, 1000 ether);
        token1.mint(eve, 1000 ether);

        vm.startPrank(eve);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        uint256 balance0Before = token0.balanceOf(eve);
        uint256 balance1Before = token1.balanceOf(eve);

        // eve 添加流动性
        vm.prank(eve);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10e18,
                salt: 0
            }),
            ZERO_BYTES
        );

        uint256 balance0After = token0.balanceOf(eve);
        uint256 balance1After = token1.balanceOf(eve);

        // 添加流动性后余额应减少
        assertLt(balance0After, balance0Before, "eve token0 balance should decrease after adding liquidity");
        assertLt(balance1After, balance1Before, "eve token1 balance should decrease after adding liquidity");

        console.log("token0 deposited:", balance0Before - balance0After);
        console.log("token1 deposited:", balance1Before - balance1After);
    }

    /// @notice 查询多个账户余额，验证各账户独立
    function test_tokenBalance_multipleAccounts() public {
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));

        // 为不同账户铸造不同数量
        token0.mint(alice,   100 ether);
        token0.mint(bob,     200 ether);
        token0.mint(charlie, 300 ether);

        assertEq(token0.balanceOf(alice),   100 ether, "alice balance");
        assertEq(token0.balanceOf(bob),     200 ether, "bob balance");
        assertEq(token0.balanceOf(charlie), 300 ether, "charlie balance");

        // 验证各账户余额相互独立（alice 转账不影响 charlie）
        vm.prank(alice);
        token0.transfer(bob, 50 ether);

        assertEq(token0.balanceOf(alice),   50 ether,  "alice after transfer");
        assertEq(token0.balanceOf(bob),     250 ether, "bob after transfer");
        assertEq(token0.balanceOf(charlie), 300 ether, "charlie unchanged");
    }

    // ═══════════════════════════════════════════════════════════
    // Fuzz 测试
    // ═══════════════════════════════════════════════════════════

    /// @notice Fuzz：费率分段规则对所有 volume 值成立
    function testFuzz_computeFee(uint256 volume) public view {
        uint24 fee = hook._computeFeePublic(volume);
        if (volume < hook.LOW_VOLUME_THRESHOLD()) {
            assertEq(fee, hook.HIGH_FEE(), "should be HIGH_FEE for low volume");
        } else if (volume < hook.HIGH_VOLUME_THRESHOLD()) {
            assertEq(fee, hook.MID_FEE(), "should be MID_FEE for mid volume");
        } else {
            assertEq(fee, hook.LOW_FEE(), "should be LOW_FEE for high volume");
        }
    }

    /// @notice Fuzz：时间窗口过期后 volume 重置
    function testFuzz_volumeReset(uint256 timeElapsed) public {
        // 约束：时间推进量必须超过 TIME_WINDOW
        timeElapsed = bound(timeElapsed, hook.TIME_WINDOW() + 1, type(uint32).max);

        // 先累积一些交易量
        swap(poolKey, true, -50 ether, ZERO_BYTES);
        (uint256 volBefore,) = hook.poolVolumes(poolId);
        assertGt(volBefore, 0, "should have volume before reset");

        // 推进时间
        vm.warp(block.timestamp + timeElapsed);

        // 执行新 swap 触发重置
        swap(poolKey, true, -1 ether, ZERO_BYTES);

        (uint256 volAfter,) = hook.poolVolumes(poolId);
        // 重置后只有本次 swap 的量
        assertEq(volAfter, 1 ether, "volume should be reset to just this swap");
    }
}
