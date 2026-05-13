// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";

// 使用方式：
//   forge script script/Interact.s.sol:MintTokens    --rpc-url http://localhost:8545 --broadcast
//   forge script script/Interact.s.sol:TransferTokens --rpc-url http://localhost:8545 --broadcast
//   forge script script/Interact.s.sol:CheckBalances  --rpc-url http://localhost:8545
//   forge script script/Interact.s.sol:DoSwap         --rpc-url http://localhost:8545 --broadcast

// ─── 已部署合约地址（从 DeployHook 输出复制）────────────────────
address constant POOL_MANAGER = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
address constant TOKEN0       = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
address constant TOKEN1       = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
address constant HOOK         = 0xfFfffFffFFffffffffffFffffFfFfffffFFFc0C0;

// Anvil 测试账户（账户 0 = 部署者，账户 1 = 接收方）
uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
uint256 constant ACCOUNT1_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
address constant DEPLOYER     = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
address constant ACCOUNT1     = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

// ─── 1. 铸造代币给多个账户 ───────────────────────────────────────
contract MintTokens is Script {
    function run() external {
        vm.startBroadcast(DEPLOYER_KEY);

        MockERC20 token0 = MockERC20(TOKEN0);
        MockERC20 token1 = MockERC20(TOKEN1);

        token0.mint(ACCOUNT1, 1000 ether);
        token1.mint(ACCOUNT1, 1000 ether);

        console.log("=== Minted tokens to ACCOUNT1 ===");
        console.log("ACCOUNT1:", ACCOUNT1);
        console.log("Token0 balance:", token0.balanceOf(ACCOUNT1));
        console.log("Token1 balance:", token1.balanceOf(ACCOUNT1));

        vm.stopBroadcast();
    }
}

// ─── 2. 账户间代币转账 ───────────────────────────────────────────
contract TransferTokens is Script {
    function run() external {
        MockERC20 token0 = MockERC20(TOKEN0);

        console.log("=== Before Transfer ===");
        console.log("DEPLOYER token0:", token0.balanceOf(DEPLOYER));
        console.log("ACCOUNT1 token0:", token0.balanceOf(ACCOUNT1));

        vm.startBroadcast(DEPLOYER_KEY);
        token0.transfer(ACCOUNT1, 100 ether);
        vm.stopBroadcast();

        console.log("=== After Transfer (100 ether token0: DEPLOYER -> ACCOUNT1) ===");
        console.log("DEPLOYER token0:", token0.balanceOf(DEPLOYER));
        console.log("ACCOUNT1 token0:", token0.balanceOf(ACCOUNT1));
    }
}

// ─── 3. 查询余额（只读，无需广播）───────────────────────────────
contract CheckBalances is Script {
    using StateLibrary for IPoolManager;

    function run() external view {
        MockERC20 token0 = MockERC20(TOKEN0);
        MockERC20 token1 = MockERC20(TOKEN1);

        console.log("=== Token Balances ===");
        console.log("DEPLOYER  token0:", token0.balanceOf(DEPLOYER));
        console.log("DEPLOYER  token1:", token1.balanceOf(DEPLOYER));
        console.log("ACCOUNT1  token0:", token0.balanceOf(ACCOUNT1));
        console.log("ACCOUNT1  token1:", token1.balanceOf(ACCOUNT1));
        console.log("Token0 totalSupply:", token0.totalSupply());
        console.log("Token1 totalSupply:", token1.totalSupply());

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        PoolId poolId = poolKey.toId();

        IPoolManager pm = IPoolManager(POOL_MANAGER);
        (uint160 sqrtPriceX96, int24 tick,,) = pm.getSlot0(poolId);
        console.log("\n=== Pool State ===");
        console.log("sqrtPriceX96:", sqrtPriceX96);
        console.log("Current tick:", tick);
    }
}

// ─── 4. 执行 Swap ────────────────────────────────────────────────
contract DoSwap is Script {
    using StateLibrary for IPoolManager;

    function run() external {
        MockERC20 token0 = MockERC20(TOKEN0);
        MockERC20 token1 = MockERC20(TOKEN1);
        IPoolManager pm = IPoolManager(POOL_MANAGER);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        PoolId poolId = poolKey.toId();

        vm.startBroadcast(DEPLOYER_KEY);

        // 重新 etch hook（vm.etch 在广播模式下也有效）
        DynamicFeeHook impl = new DynamicFeeHook(pm);
        vm.etch(HOOK, address(impl).code);
        DynamicFeeHook hook = DynamicFeeHook(HOOK);

        // 部署 SwapRouter 和 LiquidityRouter
        PoolSwapTest swapRouter = new PoolSwapTest(pm);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(pm);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);

        // 添加流动性
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10_000e18,
                salt: 0
            }),
            ""
        );

        console.log("=== Before Swap ===");
        console.log("DEPLOYER token0:", token0.balanceOf(DEPLOYER));
        console.log("DEPLOYER token1:", token1.balanceOf(DEPLOYER));
        (uint256 volBefore,) = hook.poolVolumes(poolId);
        console.log("Pool cumulative volume:", volBefore);
        console.log("Current fee:", hook._computeFeePublic(volBefore));

        // 执行 swap：token0 -> token1，exactInput 5 ether
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -5 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        console.log("\n=== After Swap (5 ether token0 -> token1) ===");
        console.log("DEPLOYER token0:", token0.balanceOf(DEPLOYER));
        console.log("DEPLOYER token1:", token1.balanceOf(DEPLOYER));
        (uint256 volAfter,) = hook.poolVolumes(poolId);
        console.log("Pool cumulative volume:", volAfter);
        console.log("Current fee:", hook._computeFeePublic(volAfter));

        vm.stopBroadcast();
    }
}
