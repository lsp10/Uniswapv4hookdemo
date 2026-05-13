# 需求文档

## 简介

本项目基于 Foundry 开发框架，实现一个 Uniswap v4 动态手续费 Hook 智能合约。该 Hook 根据流动性池的历史交易量动态调整手续费费率：交易量越高，费率越低（流动性激励）；交易量越低，费率越高（保护流动性提供者）。项目包含完整的合约实现、本地部署脚本以及 Foundry 测试套件。

---

## 词汇表

- **Hook**：Uniswap v4 中在特定生命周期事件（如 swap 前后、流动性变更前后）被自动调用的智能合约扩展点。
- **PoolManager**：Uniswap v4 核心合约，统一管理所有流动性池的状态与操作。
- **PoolKey**：唯一标识一个 Uniswap v4 流动性池的结构体，包含两种代币地址、手续费等级、tick 间距和 Hook 地址。
- **DynamicFeeHook**：本项目实现的动态手续费 Hook 合约。
- **SwapVolume**：在指定时间窗口内，某流动性池累计的交易量（以 token0 计价的绝对值之和）。
- **FeeRate**：流动性池对每笔 swap 收取的手续费比例，单位为 pips（百万分之一，即 1 pip = 0.0001%）。
- **TimeWindow**：用于计算 SwapVolume 的滚动时间窗口，默认为 1 小时（3600 秒）。
- **BaseFeeTier**：手续费费率的基准档位，分为低、中、高三档。
- **Foundry**：基于 Rust 的 Solidity 智能合约开发框架，包含 forge（编译/测试）、cast（链上交互）、anvil（本地节点）。
- **Anvil**：Foundry 内置的本地以太坊测试节点。

---

## 需求

### 需求 1：项目结构与依赖配置

**用户故事：** 作为开发者，我希望拥有一个结构完整、依赖齐全的 Foundry 项目，以便能够编译、测试和部署 Uniswap v4 Hook 合约。

#### 验收标准

1. THE DynamicFeeHook 项目 SHALL 包含标准 Foundry 目录结构：`src/`（合约源码）、`test/`（测试文件）、`script/`（部署脚本）、`lib/`（依赖库）。
2. THE DynamicFeeHook 项目 SHALL 通过 `foundry.toml` 配置文件声明编译器版本为 Solidity `^0.8.24`，并启用 `via-ir` 优化。
3. THE DynamicFeeHook 项目 SHALL 通过 git submodule 引入以下依赖：`v4-core`（Uniswap v4 核心合约）、`v4-periphery`（Uniswap v4 外围合约）、`forge-std`（Foundry 标准库）。
4. WHEN 执行 `forge build` 命令时，THE DynamicFeeHook 项目 SHALL 在无编译错误的情况下完成编译。

---

### 需求 2：动态手续费 Hook 合约实现

**用户故事：** 作为开发者，我希望实现一个根据交易量动态调整手续费的 Hook 合约，以便演示 Uniswap v4 Hook 机制的核心能力。

#### 验收标准

1. THE DynamicFeeHook 合约 SHALL 继承 `BaseHook`，并实现 `IHooks` 接口。
2. THE DynamicFeeHook 合约 SHALL 在 `getHookPermissions()` 函数中声明启用 `beforeSwap` 和 `afterSwap` 两个 Hook 回调权限，其余权限均返回 `false`。
3. WHEN 部署 DynamicFeeHook 合约时，THE DynamicFeeHook 合约 SHALL 要求在构造函数中传入有效的 PoolManager 合约地址，并将其存储为不可变状态变量。
4. THE DynamicFeeHook 合约 SHALL 为每个 PoolKey 独立维护一个 SwapVolume 累计器，记录在当前 TimeWindow 内的累计交易量。
5. WHEN `afterSwap` 回调被 PoolManager 调用时，THE DynamicFeeHook 合约 SHALL 将本次 swap 的交易量（取 `amountSpecified` 的绝对值）累加到对应 PoolKey 的 SwapVolume 累计器中。
6. WHEN 当前时间戳超过上次重置时间戳加 TimeWindow（3600 秒）时，THE DynamicFeeHook 合约 SHALL 在下一次 `beforeSwap` 调用时将对应 PoolKey 的 SwapVolume 累计器重置为零，并更新重置时间戳。
7. WHEN `beforeSwap` 回调被 PoolManager 调用时，THE DynamicFeeHook 合约 SHALL 根据以下规则计算并返回动态 FeeRate：
   - WHILE SwapVolume 小于 `LOW_VOLUME_THRESHOLD`（默认 10 ether）时，THE DynamicFeeHook 合约 SHALL 返回高费率 `HIGH_FEE`（默认 10000 pips，即 1%）。
   - WHILE SwapVolume 大于等于 `LOW_VOLUME_THRESHOLD` 且小于 `HIGH_VOLUME_THRESHOLD`（默认 100 ether）时，THE DynamicFeeHook 合约 SHALL 返回中费率 `MID_FEE`（默认 3000 pips，即 0.3%）。
   - WHILE SwapVolume 大于等于 `HIGH_VOLUME_THRESHOLD` 时，THE DynamicFeeHook 合约 SHALL 返回低费率 `LOW_FEE`（默认 500 pips，即 0.05%）。
8. THE DynamicFeeHook 合约 SHALL 将 `LOW_VOLUME_THRESHOLD`、`HIGH_VOLUME_THRESHOLD`、`HIGH_FEE`、`MID_FEE`、`LOW_FEE` 声明为 `public constant`，以便外部查询和测试验证。
9. THE DynamicFeeHook 合约 SHALL 在 `afterSwap` 更新 SwapVolume 后，发出包含 `poolId`、`newVolume`、`currentFee` 字段的 `VolumeUpdated` 事件。
10. IF DynamicFeeHook 合约的任意 Hook 回调被非 PoolManager 地址调用，THEN THE DynamicFeeHook 合约 SHALL 回滚交易并返回 `NotPoolManager()` 错误。

---

### 需求 3：Hook 地址挖矿与部署约束

**用户故事：** 作为开发者，我希望 Hook 合约能够被部署到满足 Uniswap v4 地址约束的地址，以便 PoolManager 能够正确识别并调用 Hook 权限。

#### 验收标准

1. THE DynamicFeeHook 合约地址 SHALL 满足 Uniswap v4 的 Hook 地址位掩码约束：合约地址的低 14 位必须与 `getHookPermissions()` 返回的权限位图完全匹配。
2. THE 部署脚本 SHALL 使用 `HookMiner` 工具库（来自 `v4-periphery`）通过 CREATE2 预计算满足地址约束的 salt 值。
3. WHEN `HookMiner.find()` 找到有效 salt 后，THE 部署脚本 SHALL 使用该 salt 通过 CREATE2 部署 DynamicFeeHook 合约。
4. IF 部署后的合约地址与 `HookMiner` 预计算地址不一致，THEN THE 部署脚本 SHALL 回滚并输出错误信息 `"Hook address mismatch"`。

---

### 需求 4：本地部署脚本

**用户故事：** 作为开发者，我希望拥有一个完整的本地部署脚本，以便在 Anvil 本地节点上一键部署完整的 Uniswap v4 环境和 Hook 合约。

#### 验收标准

1. THE 部署脚本 SHALL 以 Foundry Script 形式实现（继承 `Script`），文件路径为 `script/DeployHook.s.sol`。
2. THE 部署脚本 SHALL 在 `run()` 函数中按以下顺序执行：部署 PoolManager → 部署 DynamicFeeHook → 初始化流动性池 → 部署测试用 ERC20 代币（Token0、Token1）。
3. WHEN 执行 `forge script script/DeployHook.s.sol --rpc-url http://localhost:8545 --broadcast` 命令时，THE 部署脚本 SHALL 在 Anvil 节点上成功完成所有合约部署，并将各合约地址输出到控制台。
4. THE 部署脚本 SHALL 使用 Anvil 默认测试账户（私钥 `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`）作为部署者。
5. WHEN 流动性池初始化时，THE 部署脚本 SHALL 使用 `sqrtPriceX96` 对应 1:1 初始价格（即 `79228162514264337593543950336`）调用 `PoolManager.initialize()`。

---

### 需求 5：Foundry 测试套件

**用户故事：** 作为开发者，我希望拥有覆盖核心逻辑的完整测试套件，以便验证动态手续费 Hook 的正确性。

#### 验收标准

1. THE 测试套件 SHALL 包含测试文件 `test/DynamicFeeHook.t.sol`，继承 `Test` 和 `Deployers`（来自 `v4-core/test`）。
2. THE 测试套件 SHALL 在 `setUp()` 函数中完成以下初始化：部署 PoolManager、通过 HookMiner 部署 DynamicFeeHook、创建并初始化测试流动性池、为测试账户铸造足量测试代币并添加初始流动性。
3. WHEN 测试账户在 TimeWindow 内累计 swap 交易量低于 `LOW_VOLUME_THRESHOLD` 时，THE 测试套件 SHALL 验证 `beforeSwap` 返回的 FeeRate 等于 `HIGH_FEE`（10000 pips）。
4. WHEN 测试账户在 TimeWindow 内累计 swap 交易量介于 `LOW_VOLUME_THRESHOLD` 和 `HIGH_VOLUME_THRESHOLD` 之间时，THE 测试套件 SHALL 验证 `beforeSwap` 返回的 FeeRate 等于 `MID_FEE`（3000 pips）。
5. WHEN 测试账户在 TimeWindow 内累计 swap 交易量超过 `HIGH_VOLUME_THRESHOLD` 时，THE 测试套件 SHALL 验证 `beforeSwap` 返回的 FeeRate 等于 `LOW_FEE`（500 pips）。
6. WHEN 使用 `vm.warp()` 将时间戳推进超过 TimeWindow（3600 秒）后执行新的 swap 时，THE 测试套件 SHALL 验证 SwapVolume 累计器已被重置为零，且 FeeRate 恢复为 `HIGH_FEE`。
7. WHEN `afterSwap` 被调用时，THE 测试套件 SHALL 验证 `VolumeUpdated` 事件被正确发出，且事件中的 `newVolume` 字段与预期累计交易量一致。
8. WHEN 非 PoolManager 地址直接调用 DynamicFeeHook 的 `beforeSwap` 函数时，THE 测试套件 SHALL 验证交易回滚并携带 `NotPoolManager()` 错误。
9. WHEN 执行 `forge test -vv` 命令时，THE 测试套件 SHALL 全部测试通过，且无任何测试跳过或失败。
