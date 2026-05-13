# Uniswap v4 DynamicFeeHook — 本地部署与钱包连接指南

## 已部署合约地址（Anvil 本地网络）

| 合约 | 地址 |
|------|------|
| PoolManager | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| DynamicFeeHook | `0xfFfffFffFFffffffffffFffffFfFfffffFFFc0C0` |
| Token0 (TKA) | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| Token1 (TKB) | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |

## Anvil 测试账户

| 账户 | 地址 | 私钥 |
|------|------|------|
| 账户 0（部署者） | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` |
| 账户 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` |
| 账户 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` |

---

## 第一步：启动 Anvil

```bash
# 启动本地节点（Chain ID: 31337，每 2 秒出一个块）
anvil --chain-id 31337 --block-time 2
```

## 第二步：部署合约

```bash
forge script script/DeployHook.s.sol --rpc-url http://localhost:8545 --broadcast
```

---

## 连接 MetaMask 钱包

### 1. 添加 Anvil 本地网络

在 MetaMask 中点击「添加网络」→「手动添加网络」：

| 字段 | 值 |
|------|-----|
| 网络名称 | Anvil Local |
| RPC URL | `http://127.0.0.1:8545` |
| Chain ID | `31337` |
| 货币符号 | ETH |

### 2. 导入测试账户

在 MetaMask 中点击「导入账户」→ 粘贴私钥：

```
账户 0 私钥：0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
账户 1 私钥：0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
```

> ⚠️ 这些是 Anvil 公开测试私钥，仅用于本地开发，切勿用于主网。

### 3. 添加代币到 MetaMask

在 MetaMask 中点击「导入代币」→ 粘贴合约地址：

- Token0: `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`（符号：TKA，精度：18）
- Token1: `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`（符号：TKB，精度：18）

---

## 使用 cast 命令行交互

### 查询余额

```bash
# 查询 ETH 余额
cast balance 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url http://localhost:8545

# 查询 Token0 余额（账户 0）
cast call 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 \
  "balanceOf(address)(uint256)" \
  0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --rpc-url http://localhost:8545

# 查询 Token0 余额（账户 1）
cast call 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 \
  "balanceOf(address)(uint256)" \
  0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  --rpc-url http://localhost:8545

# 查询 Token0 总供应量
cast call 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 \
  "totalSupply()(uint256)" \
  --rpc-url http://localhost:8545
```

### 代币转账

```bash
# 账户 0 转账 50 ether Token0 给账户 1
cast send 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 \
  "transfer(address,uint256)(bool)" \
  0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  50000000000000000000 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545

# 账户 1 转账 10 ether Token0 给账户 2
cast send 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 \
  "transfer(address,uint256)(bool)" \
  0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
  10000000000000000000 \
  --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
  --rpc-url http://localhost:8545
```

### 铸造代币（MockERC20 特有功能）

```bash
# 给账户 1 铸造 1000 ether Token0
cast send 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0 \
  "mint(address,uint256)" \
  0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  1000000000000000000000 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545
```

### 查询池状态

```bash
# 查询池的 sqrtPriceX96 和当前 tick
# Pool ID: 0x0fa928352400dca459a8341f495a4bed3e3619027b15a85156d30f72674f3905
cast call 0x5FbDB2315678afecb367f032d93F642f64180aa3 \
  "getSlot0(bytes32)(uint160,int24,uint24,uint24)" \
  0x0fa928352400dca459a8341f495a4bed3e3619027b15a85156d30f72674f3905 \
  --rpc-url http://localhost:8545
```

---

## 使用 Foundry 脚本批量操作

```bash
# 铸造代币给账户 1
forge script script/Interact.s.sol:MintTokens \
  --rpc-url http://localhost:8545 --broadcast

# 账户间转账
forge script script/Interact.s.sol:TransferTokens \
  --rpc-url http://localhost:8545 --broadcast

# 查询余额（只读，无需广播）
forge script script/Interact.s.sol:CheckBalances \
  --rpc-url http://localhost:8545
```

---

## 动态费率说明

| 1小时内累计交易量 | 手续费率 |
|-----------------|---------|
| < 10 ETH | 1%（HIGH_FEE = 10000 pips） |
| 10 ~ 100 ETH | 0.3%（MID_FEE = 3000 pips） |
| ≥ 100 ETH | 0.05%（LOW_FEE = 500 pips） |

每隔 3600 秒（1小时），交易量累计器自动重置为零。

---

## 运行测试

```bash
# 运行所有测试（16 个）
forge test -vv

# 运行单个测试
forge test --match-test test_highFee_lowVolume -vv

# 运行 Fuzz 测试
forge test --match-test testFuzz -vv
```
