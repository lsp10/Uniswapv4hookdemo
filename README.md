# Uniswap v4 动态手续费 Hook 演示

基于 [Foundry](https://book.getfoundry.sh/) 开发的 Uniswap v4 Hook 示例项目。实现了一个**动态手续费 Hook**，根据流动性池在滚动时间窗口（1 小时）内的累计交易量自动调整手续费费率。

## 功能特性

- **三档动态费率**：交易量越高，费率越低，激励活跃交易
- **滚动时间窗口**：每小时自动重置交易量累计器
- **链上事件**：每次 swap 后发出 `VolumeUpdated` 事件，记录最新交易量和当前费率
- **访问控制**：Hook 回调仅允许 PoolManager 调用

| 1 小时内累计交易量 | 手续费率 |
|-----------------|---------|
| < 10 ETH | **1%**（HIGH_FEE，保护低流动性） |
| 10 ~ 100 ETH | **0.3%**（MID_FEE，标准费率） |
| ≥ 100 ETH | **0.05%**（LOW_FEE，激励高频交易） |

## 项目结构

```
.
├── src/
│   └── DynamicFeeHook.sol       # 核心 Hook 合约
├── test/
│   └── DynamicFeeHook.t.sol     # Foundry 测试套件（16 个测试）
├── script/
│   ├── DeployHook.s.sol         # 本地部署脚本
│   └── Interact.s.sol           # 交互脚本（铸币/转账/Swap/余额查询）
├── lib/
│   ├── v4-core/                 # Uniswap v4 核心合约（git submodule）
│   ├── v4-periphery/            # Uniswap v4 外围合约（git submodule）
│   └── forge-std/               # Foundry 标准库（git submodule）
├── foundry.toml                 # Foundry 配置
└── GUIDE.md                     # 本地部署与钱包连接详细指南
```

## 环境要求

- [Foundry](https://book.getfoundry.sh/getting-started/installation)（forge、cast、anvil）
- Git

## 快速开始

### 1. 克隆仓库并初始化依赖

```bash
git clone <仓库地址>
cd Uniswapv4hookdemo

# 初始化所有 git submodule（v4-core、v4-periphery、forge-std 及其嵌套依赖）
git submodule update --init --recursive
```

### 2. 编译合约

```bash
forge build
```

### 3. 运行测试

```bash
# 运行全部 16 个测试
forge test -vv
```

测试覆盖范围：

| 测试 | 说明 |
|------|------|
| `test_highFee_lowVolume` | 低交易量时费率为 1% |
| `test_midFee_midVolume` | 中等交易量时费率为 0.3% |
| `test_lowFee_highVolume` | 高交易量时费率为 0.05% |
| `test_volumeReset_afterTimeWindow` | 时间窗口过期后交易量重置 |
| `test_volumeUpdated_event` | VolumeUpdated 事件字段正确 |
| `test_revert_notPoolManager` | 非 PoolManager 调用回滚 |
| `test_tokenTransfer_betweenAccounts` | 账户间代币转账 |
| `test_tokenTransfer_insufficientBalance_reverts` | 余额不足时转账回滚 |
| `test_tokenBalance_afterMint` | 铸造后余额正确 |
| `test_tokenBalance_afterSwap` | Swap 后余额变化正确 |
| `test_tokenBalance_afterLiquidityAdd` | 添加流动性后余额减少 |
| `testFuzz_computeFee` | Fuzz：费率分段规则对所有交易量成立 |
| `testFuzz_volumeReset` | Fuzz：任意超时后交易量重置 |
| ... | 共 16 个测试，全部通过 |

### 4. 本地部署

```bash
# 启动 Anvil 本地节点
anvil --chain-id 31337 --block-time 2

# 新开终端，运行部署脚本
forge script script/DeployHook.s.sol --rpc-url http://localhost:8545 --broadcast
```

部署成功后输出示例：

```
PoolManager:    0x5FbDB2315678afecb367f032d93F642f64180aa3
DynamicFeeHook: 0xfFfffFffFFffffffffffFffffFfFfffffFFFc0C0
Token0:         0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
Token1:         0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
```

### 5. 与合约交互（cast 命令行）

```bash
# 查询代币余额
cast call <TOKEN0_ADDRESS> "balanceOf(address)(uint256)" <YOUR_ADDRESS> \
  --rpc-url http://localhost:8545

# 代币转账
cast send <TOKEN0_ADDRESS> "transfer(address,uint256)(bool)" <TO_ADDRESS> <AMOUNT> \
  --private-key <YOUR_PRIVATE_KEY> \
  --rpc-url http://localhost:8545
```

更多操作（MetaMask 连接、Swap 演示等）详见 [GUIDE.md](./GUIDE.md)。

## 合约说明

### DynamicFeeHook.sol

| 函数 | 说明 |
|------|------|
| `beforeSwap()` | 检查时间窗口是否过期，计算并返回动态费率 |
| `afterSwap()` | 累加本次交易量，发出 `VolumeUpdated` 事件 |
| `_computeFee(volume)` | 根据累计交易量返回对应费率 |
| `_computeFeePublic(volume)` | 公开版费率计算（供测试使用） |
| `poolVolumes(poolId)` | 查询指定池的累计交易量和上次重置时间 |

### 关键常量

| 常量 | 值 | 说明 |
|------|----|------|
| `HIGH_FEE` | 10000 pips | 1% |
| `MID_FEE` | 3000 pips | 0.3% |
| `LOW_FEE` | 500 pips | 0.05% |
| `LOW_VOLUME_THRESHOLD` | 10 ETH | 低/中量分界 |
| `HIGH_VOLUME_THRESHOLD` | 100 ETH | 中/高量分界 |
| `TIME_WINDOW` | 3600 秒 | 滚动时间窗口 |

## 技术栈

- **Solidity** ^0.8.26
- **Foundry** — 编译、测试、部署
- **Uniswap v4-core** — PoolManager、Hooks、PoolKey
- **Uniswap v4-periphery** — 测试工具（Deployers）

## 参考资料

- [Uniswap v4 文档](https://docs.uniswap.org/contracts/v4/overview)
- [Uniswap v4-core 源码](https://github.com/Uniswap/v4-core)
- [Foundry 文档](https://book.getfoundry.sh/)
- [Uniswap v4 Hook 开发指南](https://docs.uniswap.org/contracts/v4/guides/hooks/your-first-hook)
