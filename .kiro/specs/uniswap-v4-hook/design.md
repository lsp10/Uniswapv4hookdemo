# 技术设计文档：Uniswap v4 动态手续费 Hook

## 简介

本文档描述基于 Foundry 框架实现的 Uniswap v4 动态手续费 Hook 合约的技术设计。系统核心是 `DynamicFeeHook` 合约，通过 `beforeSwap` / `afterSwap` 两个生命周期回调，在滚动时间窗口内统计交易量并动态调整手续费费率。

---

## 高层设计

### 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                        用户 / 测试脚本                        │
└──────────────────────────┬──────────────────────────────────┘
                           │ swap()
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    Uniswap v4 PoolManager                    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Pool State (reserves, ticks, liquidity, fee, ...)  │    │
│  └─────────────────────────────────────────────────────┘    │
│         │ beforeSwap()              │ afterSwap()            │
└─────────┼──────────────────────────┼────────────────────────┘
          │                          │
          ▼                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    DynamicFeeHook                            │
│                                                              │
│  ┌──────────────────────┐   ┌──────────────────────────┐    │
│  │  VolumeTracker       │   │  FeeCalculator           │    │
│  │  poolVolumes mapping │   │  _computeFee(volume)     │    │
│  │  lastReset mapping   │   │  三档费率逻辑             │    │
│  └──────────────────────┘   └──────────────────────────┘    │
│                                                              │
│  emit VolumeUpdated(poolId, newVolume, currentFee)           │
└─────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────┐
│                    部署基础设施                               │
│  HookMiner (CREATE2 salt 计算)                               │
│  DeployHook.s.sol (Foundry Script)                           │
└─────────────────────────────────────────────────────────────┘
```

### 组件关系

| 组件 | 类型 | 职责 |
|------|------|------|
| `PoolManager` | 外部合约（v4-core） | 管理所有池状态，在 swap 前后调用 Hook |
| `BaseHook` | 抽象合约（v4-periphery） | 提供 Hook 权限声明框架和 `onlyPoolManager` 修饰符 |
| `DynamicFeeHook` | 核心合约（本项目） | 实现动态费率逻辑，维护 volume 状态 |
| `HookMiner` | 工具库（v4-periphery） | 通过 CREATE2 暴力搜索满足地址约束的 salt |
| `DeployHook.s.sol` | 部署脚本 | 编排完整部署流程 |
| `DynamicFeeHook.t.sol` | 测试套件 | 验证核心逻辑正确性 |

### 数据模型

#### PoolVolumeData 结构

每个 `PoolId`（`bytes32`）对应一条独立的 volume 记录：

```solidity
struct PoolVolumeData {
    uint256 cumulativeVolume;  // 当前 TimeWindow 内累计交易量（token0 绝对值，单位 wei）
    uint256 lastResetTimestamp; // 上次重置时间戳（Unix 秒）
}
```

存储布局：

```solidity
mapping(PoolId => PoolVolumeData) public poolVolumes;
```

#### 费率常量

| 常量名 | 值（pips） | 对应百分比 | 触发条件 |
|--------|-----------|-----------|---------|
| `HIGH_FEE` | 10000 | 1% | volume < LOW_VOLUME_THRESHOLD |
| `MID_FEE` | 3000 | 0.3% | LOW_VOLUME_THRESHOLD ≤ volume < HIGH_VOLUME_THRESHOLD |
| `LOW_FEE` | 500 | 0.05% | volume ≥ HIGH_VOLUME_THRESHOLD |
| `LOW_VOLUME_THRESHOLD` | 10 ether | — | 低/中量分界线 |
| `HIGH_VOLUME_THRESHOLD` | 100 ether | — | 中/高量分界线 |
| `TIME_WINDOW` | 3600 | — | 滚动窗口（秒） |

---

## 低层设计

### 合约接口

#### DynamicFeeHook.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

contract DynamicFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // ─── 常量 ───────────────────────────────────────────────
    uint24 public constant HIGH_FEE = 10000;           // 1%
    uint24 public constant MID_FEE  = 3000;            // 0.3%
    uint24 public constant LOW_FEE  = 500;             // 0.05%
    uint256 public constant LOW_VOLUME_THRESHOLD  = 10 ether;
    uint256 public constant HIGH_VOLUME_THRESHOLD = 100 ether;
    uint256 public constant TIME_WINDOW = 3600;        // 1 小时

    // ─── 状态 ───────────────────────────────────────────────
    struct PoolVolumeData {
        uint256 cumulativeVolume;
        uint256 lastResetTimestamp;
    }
    mapping(PoolId => PoolVolumeData) public poolVolumes;

    // ─── 事件 ───────────────────────────────────────────────
    event VolumeUpdated(
        PoolId indexed poolId,
        uint256 newVolume,
        uint24  currentFee
    );

    // ─── 构造函数 ────────────────────────────────────────────
    constructor(IPoolManager _poolManager) BaseHook(_poolManager);

    // ─── Hook 权限声明 ───────────────────────────────────────
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory);

    // ─── Hook 回调 ───────────────────────────────────────────
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager
      returns (bytes4 selector, BeforeSwapDelta delta, uint24 fee);

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager
      returns (bytes4 selector, int128 hookDeltaUnspecified);

    // ─── 内部辅助 ────────────────────────────────────────────
    function _computeFee(uint256 volume)
        internal
        pure
        returns (uint24 fee);

    function _maybeResetVolume(PoolId poolId)
        internal;
}
```

### 关键算法

#### beforeSwap 执行流程

```
beforeSwap(sender, key, params, hookData)
│
├─ 1. onlyPoolManager 修饰符检查（BaseHook 提供）
│      └─ 若调用者 ≠ poolManager → revert NotPoolManager()
│
├─ 2. 计算 poolId = key.toId()
│
├─ 3. _maybeResetVolume(poolId)
│      ├─ 读取 poolVolumes[poolId].lastResetTimestamp
│      └─ 若 block.timestamp > lastReset + TIME_WINDOW
│             ├─ poolVolumes[poolId].cumulativeVolume = 0
│             └─ poolVolumes[poolId].lastResetTimestamp = block.timestamp
│
├─ 4. fee = _computeFee(poolVolumes[poolId].cumulativeVolume)
│      ├─ volume < LOW_VOLUME_THRESHOLD  → HIGH_FEE (10000)
│      ├─ volume < HIGH_VOLUME_THRESHOLD → MID_FEE  (3000)
│      └─ volume ≥ HIGH_VOLUME_THRESHOLD → LOW_FEE  (500)
│
└─ 5. return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee)
```

#### afterSwap 执行流程

```
afterSwap(sender, key, params, delta, hookData)
│
├─ 1. onlyPoolManager 修饰符检查
│
├─ 2. 计算 poolId = key.toId()
│
├─ 3. 计算本次交易量
│      └─ volume = uint256(params.amountSpecified < 0
│                          ? -params.amountSpecified
│                          : params.amountSpecified)
│
├─ 4. 更新累计量
│      └─ poolVolumes[poolId].cumulativeVolume += volume
│
├─ 5. 计算当前费率（用于事件）
│      └─ currentFee = _computeFee(poolVolumes[poolId].cumulativeVolume)
│
├─ 6. emit VolumeUpdated(poolId, poolVolumes[poolId].cumulativeVolume, currentFee)
│
└─ 7. return (BaseHook.afterSwap.selector, 0)
```

#### _computeFee 费率分段逻辑

```solidity
function _computeFee(uint256 volume) internal pure returns (uint24 fee) {
    if (volume < LOW_VOLUME_THRESHOLD) {
        return HIGH_FEE;  // 10000 pips = 1%
    } else if (volume < HIGH_VOLUME_THRESHOLD) {
        return MID_FEE;   // 3000 pips = 0.3%
    } else {
        return LOW_FEE;   // 500 pips = 0.05%
    }
}
```

#### Hook 地址位掩码约束

Uniswap v4 要求 Hook 合约地址的低 14 位与权限位图匹配。`DynamicFeeHook` 启用 `beforeSwap`（bit 7）和 `afterSwap`（bit 6），对应权限位图：

```
Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
```

`HookMiner.find()` 算法：

```
输入: deployer 地址, creationCode, constructorArgs, flags（权限位图）
输出: (address hookAddress, bytes32 salt)

循环:
  salt = keccak256(abi.encodePacked(deployer, counter++))
  predictedAddr = CREATE2(deployer, salt, keccak256(creationCode ++ constructorArgs))
  if (uint160(predictedAddr) & HookMiner.FLAG_MASK == flags):
    return (predictedAddr, salt)
```

### 项目目录结构

```
Uniswapv4hookdemo/
├── foundry.toml                    # Foundry 配置
├── .gitmodules                     # git submodule 声明
├── lib/
│   ├── v4-core/                    # Uniswap v4 核心合约
│   ├── v4-periphery/               # Uniswap v4 外围合约（含 BaseHook、HookMiner）
│   └── forge-std/                  # Foundry 标准库
├── src/
│   └── DynamicFeeHook.sol          # 核心 Hook 合约
├── script/
│   └── DeployHook.s.sol            # 本地部署脚本
└── test/
    └── DynamicFeeHook.t.sol        # Foundry 测试套件
```

### foundry.toml 配置

```toml
[profile.default]
src     = "src"
out     = "out"
libs    = ["lib"]
solc    = "0.8.24"
via_ir  = true
optimizer = true
optimizer_runs = 200

remappings = [
  "v4-core/=lib/v4-core/",
  "v4-periphery/=lib/v4-periphery/",
  "forge-std/=lib/forge-std/src/",
]
```

### DeployHook.s.sol 部署流程

```
run()
│
├─ 1. vm.startBroadcast(ANVIL_PRIVATE_KEY)
│
├─ 2. 部署 PoolManager
│      └─ poolManager = new PoolManager(address(0))
│
├─ 3. 部署测试 ERC20 代币
│      ├─ token0 = new MockERC20("Token0", "TK0", 18)
│      └─ token1 = new MockERC20("Token1", "TK1", 18)
│         （确保 address(token0) < address(token1)）
│
├─ 4. HookMiner 计算 salt
│      └─ (hookAddr, salt) = HookMiner.find(
│             address(this),
│             type(DynamicFeeHook).creationCode,
│             abi.encode(address(poolManager)),
│             uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)
│         )
│
├─ 5. CREATE2 部署 DynamicFeeHook
│      └─ hook = new DynamicFeeHook{salt: salt}(poolManager)
│         require(address(hook) == hookAddr, "Hook address mismatch")
│
├─ 6. 构造 PoolKey 并初始化流动性池
│      ├─ key = PoolKey(token0, token1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook))
│      └─ poolManager.initialize(key, SQRT_PRICE_1_1)
│         （SQRT_PRICE_1_1 = 79228162514264337593543950336）
│
└─ 7. vm.stopBroadcast()
       console.log 输出各合约地址
```

### DynamicFeeHook.t.sol 测试结构

```
DynamicFeeHookTest
├── setUp()
│   ├─ deployFreshManagerAndRouters()   // Deployers 提供
│   ├─ HookMiner 部署 DynamicFeeHook
│   ├─ 创建并初始化测试池
│   ├─ 铸造测试代币
│   └─ 添加初始流动性
│
├─ test_highFee_lowVolume()
│   └─ 执行小额 swap（< 10 ether），验证费率 == HIGH_FEE
│
├─ test_midFee_midVolume()
│   └─ 执行中等 swap（≥ 10 ether，< 100 ether），验证费率 == MID_FEE
│
├─ test_lowFee_highVolume()
│   └─ 执行大额 swap（≥ 100 ether），验证费率 == LOW_FEE
│
├─ test_volumeReset_afterTimeWindow()
│   ├─ 执行 swap 累积 volume
│   ├─ vm.warp(block.timestamp + 3601)
│   └─ 再次 swap，验证 volume 重置，费率恢复 HIGH_FEE
│
├─ test_volumeUpdated_event()
│   └─ vm.expectEmit + swap，验证 VolumeUpdated 事件字段
│
└─ test_revert_notPoolManager()
    └─ vm.prank(address(0xdead)) + 直接调用 beforeSwap，验证 revert NotPoolManager()
```

---

## 正确性属性

*属性是在系统所有有效执行中都应成立的特征或行为——本质上是关于系统应做什么的形式化陈述。属性是人类可读规范与机器可验证正确性保证之间的桥梁。*

### 属性 1：各 PoolKey 的 volume 相互独立

*对于任意两个不同的 PoolKey，对其中一个执行 swap 后，另一个 PoolKey 的累计 volume 不应发生变化。*

**Validates: Requirements 2.4**

---

### 属性 2：afterSwap 正确累加交易量

*对于任意 `amountSpecified`（正数或负数），执行 afterSwap 后，对应 PoolKey 的 `cumulativeVolume` 应恰好增加 `|amountSpecified|`。*

**Validates: Requirements 2.5**

---

### 属性 3：费率分段规则对所有 volume 值成立

*对于任意非负整数 volume：*
- *若 volume < LOW_VOLUME_THRESHOLD，则 `_computeFee(volume)` 返回 HIGH_FEE（10000）*
- *若 LOW_VOLUME_THRESHOLD ≤ volume < HIGH_VOLUME_THRESHOLD，则返回 MID_FEE（3000）*
- *若 volume ≥ HIGH_VOLUME_THRESHOLD，则返回 LOW_FEE（500）*

**Validates: Requirements 2.7, 5.3, 5.4, 5.5**

---

### 属性 4：时间窗口到期后 volume 重置为零

*对于任意 PoolKey 和任意超过 TIME_WINDOW（3600 秒）的时间推进量，在下一次 beforeSwap 调用时，该 PoolKey 的 `cumulativeVolume` 应被重置为零，且 `lastResetTimestamp` 更新为当前时间戳。*

**Validates: Requirements 2.6, 5.6**

---

### 属性 5：VolumeUpdated 事件字段与状态一致

*对于任意 swap 操作，afterSwap 发出的 `VolumeUpdated` 事件中的 `newVolume` 字段应等于更新后的 `poolVolumes[poolId].cumulativeVolume`，`currentFee` 字段应等于 `_computeFee(newVolume)` 的返回值。*

**Validates: Requirements 2.9, 5.7**

---

### 属性 6：非 PoolManager 调用者始终被拒绝

*对于任意非 PoolManager 地址调用 `beforeSwap` 或 `afterSwap`，交易应回滚并携带 `NotPoolManager()` 错误，且合约状态不发生任何变化。*

**Validates: Requirements 2.10, 5.8**

---

## 错误处理

| 错误 | 触发条件 | 处理方式 |
|------|---------|---------|
| `NotPoolManager()` | Hook 回调被非 PoolManager 地址调用 | `BaseHook.onlyPoolManager` 修饰符 revert |
| `"Hook address mismatch"` | CREATE2 部署地址与 HookMiner 预计算地址不一致 | 部署脚本 `require` 检查 revert |
| 整数溢出 | `cumulativeVolume` 超过 `uint256` 上限 | Solidity 0.8.x 内置溢出检查自动 revert |

---

## 依赖版本

| 依赖 | 来源 | 用途 |
|------|------|------|
| `v4-core` | `uniswap/v4-core` | PoolManager、PoolKey、Hooks、PoolId |
| `v4-periphery` | `uniswap/v4-periphery` | BaseHook、HookMiner、Deployers |
| `forge-std` | `foundry-rs/forge-std` | Test、Script、console |
