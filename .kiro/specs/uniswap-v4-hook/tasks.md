# 实现计划：Uniswap v4 动态手续费 Hook

## 概述

基于 Foundry 框架，分步实现 `DynamicFeeHook` 合约及其完整配套设施。实现顺序为：项目初始化 → 核心合约 → 部署脚本 → 测试套件，每步均在前一步基础上递进构建，最终通过 `forge test` 全量验证。

---

## 任务

- [ ] 1. 初始化 Foundry 项目结构与依赖
  - [ ] 1.1 创建标准目录结构并初始化 git submodule 依赖
    - 在项目根目录创建 `src/`、`test/`、`script/`、`lib/` 目录
    - 执行以下命令添加三个 git submodule：
      - `git submodule add https://github.com/Uniswap/v4-core lib/v4-core`
      - `git submodule add https://github.com/Uniswap/v4-periphery lib/v4-periphery`
      - `git submodule add https://github.com/foundry-rs/forge-std lib/forge-std`
    - 确认 `lib/` 下三个子目录均已正确克隆
    - _需求：1.1, 1.3_

  - [ ] 1.2 创建并配置 `foundry.toml`
    - 在项目根目录创建 `foundry.toml`，内容如下：
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
    - 验证 `forge build` 可无错误完成编译（即使 `src/` 暂时为空）
    - _需求：1.2, 1.4_

- [ ] 2. 实现 `DynamicFeeHook.sol` 核心合约
  - [ ] 2.1 定义合约骨架、常量与状态变量
    - 创建 `src/DynamicFeeHook.sol`
    - 声明 `pragma solidity ^0.8.24` 和所有必要 import（`BaseHook`、`IPoolManager`、`Hooks`、`PoolKey`、`PoolId`、`PoolIdLibrary`、`BalanceDelta`、`BeforeSwapDelta`、`BeforeSwapDeltaLibrary`）
    - 声明合约继承 `BaseHook`
    - 声明六个 `public constant`：`HIGH_FEE = 10000`、`MID_FEE = 3000`、`LOW_FEE = 500`、`LOW_VOLUME_THRESHOLD = 10 ether`、`HIGH_VOLUME_THRESHOLD = 100 ether`、`TIME_WINDOW = 3600`
    - 声明 `PoolVolumeData` 结构体（`cumulativeVolume`、`lastResetTimestamp`）
    - 声明 `mapping(PoolId => PoolVolumeData) public poolVolumes`
    - 声明 `VolumeUpdated` 事件（`PoolId indexed poolId`、`uint256 newVolume`、`uint24 currentFee`）
    - 实现构造函数 `constructor(IPoolManager _poolManager) BaseHook(_poolManager)`
    - _需求：2.1, 2.3, 2.4, 2.8, 2.9_

  - [ ] 2.2 实现 `getHookPermissions()` 与 `_computeFee()`
    - 实现 `getHookPermissions()`，返回仅启用 `beforeSwap` 和 `afterSwap` 的 `Hooks.Permissions` 结构体（其余字段均为 `false`）
    - 实现 `_computeFee(uint256 volume) internal pure returns (uint24)`：
      - `volume < LOW_VOLUME_THRESHOLD` → 返回 `HIGH_FEE`
      - `volume < HIGH_VOLUME_THRESHOLD` → 返回 `MID_FEE`
      - 否则 → 返回 `LOW_FEE`
    - _需求：2.2, 2.7_

  - [ ]* 2.3 为 `_computeFee` 编写属性测试（属性 3）
    - **属性 3：费率分段规则对所有 volume 值成立**
    - 使用 Foundry fuzzing（`testFuzz_computeFee(uint256 volume)`）验证：
      - `volume < LOW_VOLUME_THRESHOLD` 时返回 `HIGH_FEE`（10000）
      - `LOW_VOLUME_THRESHOLD ≤ volume < HIGH_VOLUME_THRESHOLD` 时返回 `MID_FEE`（3000）
      - `volume ≥ HIGH_VOLUME_THRESHOLD` 时返回 `LOW_FEE`（500）
    - **验证：需求 2.7, 5.3, 5.4, 5.5**

  - [ ] 2.4 实现 `_maybeResetVolume()` 与 `beforeSwap()`
    - 实现 `_maybeResetVolume(PoolId poolId) internal`：
      - 读取 `poolVolumes[poolId].lastResetTimestamp`
      - 若 `block.timestamp > lastResetTimestamp + TIME_WINDOW`，则将 `cumulativeVolume` 置零并更新 `lastResetTimestamp = block.timestamp`
    - 实现 `beforeSwap()` 回调（带 `onlyPoolManager` 修饰符）：
      1. 计算 `poolId = key.toId()`
      2. 调用 `_maybeResetVolume(poolId)`
      3. 调用 `_computeFee(poolVolumes[poolId].cumulativeVolume)` 得到 `fee`
      4. 返回 `(BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee)`
    - _需求：2.2, 2.6, 2.7, 2.10_

  - [ ] 2.5 实现 `afterSwap()`
    - 实现 `afterSwap()` 回调（带 `onlyPoolManager` 修饰符）：
      1. 计算 `poolId = key.toId()`
      2. 计算本次交易量：`uint256 volume = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified)`
      3. 累加：`poolVolumes[poolId].cumulativeVolume += volume`
      4. 计算 `currentFee = _computeFee(poolVolumes[poolId].cumulativeVolume)`
      5. `emit VolumeUpdated(poolId, poolVolumes[poolId].cumulativeVolume, currentFee)`
      6. 返回 `(BaseHook.afterSwap.selector, 0)`
    - _需求：2.5, 2.9, 2.10_

  - [ ]* 2.6 为 `afterSwap` 累加逻辑编写属性测试（属性 2）
    - **属性 2：afterSwap 正确累加交易量**
    - 使用 Foundry fuzzing（`testFuzz_afterSwap_volumeAccumulation(int128 amountSpecified)`）验证：
      - 执行 afterSwap 后，`cumulativeVolume` 恰好增加 `|amountSpecified|`
    - **验证：需求 2.5**

  - [ ]* 2.7 为多池隔离编写属性测试（属性 1）
    - **属性 1：各 PoolKey 的 volume 相互独立**
    - 使用 Foundry fuzzing 验证：对 poolA 执行 swap 后，poolB 的 `cumulativeVolume` 不变
    - **验证：需求 2.4**

- [ ] 3. 检查点 —— 合约编译验证
  - 执行 `forge build`，确保 `src/DynamicFeeHook.sol` 无编译错误，所有 import 路径正确解析。如有问题，请向用户反馈。

- [ ] 4. 实现 `DeployHook.s.sol` 部署脚本
  - [ ] 4.1 创建部署脚本骨架与 PoolManager 部署
    - 创建 `script/DeployHook.s.sol`
    - 声明必要 import（`Script`、`console`、`PoolManager`、`MockERC20`、`HookMiner`、`DynamicFeeHook`、`PoolKey`、`IHooks`、`Hooks`、`LPFeeLibrary`）
    - 声明常量 `ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
    - 声明常量 `SQRT_PRICE_1_1 = 79228162514264337593543950336`
    - 在 `run()` 中调用 `vm.startBroadcast(ANVIL_PRIVATE_KEY)`
    - 部署 `PoolManager`：`poolManager = new PoolManager(address(0))`
    - _需求：4.1, 4.2, 4.4_

  - [ ] 4.2 在部署脚本中集成 HookMiner 与 CREATE2 部署
    - 部署两个测试 ERC20 代币（`MockERC20`），确保 `address(token0) < address(token1)`（必要时交换）
    - 调用 `HookMiner.find()` 计算满足地址约束的 salt：
      ```solidity
      (address hookAddr, bytes32 salt) = HookMiner.find(
          address(this),
          type(DynamicFeeHook).creationCode,
          abi.encode(address(poolManager)),
          uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)
      );
      ```
    - 使用 CREATE2 部署：`hook = new DynamicFeeHook{salt: salt}(poolManager)`
    - 添加 `require(address(hook) == hookAddr, "Hook address mismatch")`
    - _需求：3.1, 3.2, 3.3, 3.4, 4.2_

  - [ ] 4.3 在部署脚本中初始化流动性池并输出地址
    - 构造 `PoolKey`：`PoolKey(token0, token1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook))`
    - 调用 `poolManager.initialize(key, SQRT_PRICE_1_1)`
    - 调用 `vm.stopBroadcast()`
    - 使用 `console.log` 输出 `poolManager`、`hook`、`token0`、`token1` 地址
    - _需求：4.2, 4.3, 4.5_

- [ ] 5. 实现 `DynamicFeeHook.t.sol` 测试套件
  - [ ] 5.1 创建测试文件骨架与 `setUp()`
    - 创建 `test/DynamicFeeHook.t.sol`
    - 声明合约继承 `Test` 和 `Deployers`（来自 `v4-core/test`）
    - 声明必要状态变量：`DynamicFeeHook hook`、`PoolKey key`、`PoolId poolId`
    - 实现 `setUp()`：
      1. 调用 `deployFreshManagerAndRouters()`（`Deployers` 提供）
      2. 使用 `HookMiner.find()` 计算 salt，通过 CREATE2 部署 `DynamicFeeHook`
      3. 部署并初始化测试流动性池（`DYNAMIC_FEE_FLAG`，tickSpacing = 60）
      4. 铸造足量测试代币（至少 1000 ether）并授权给 Router
      5. 通过 `modifyLiquidity` 添加初始流动性（覆盖 `[MIN_TICK, MAX_TICK]` 范围）
    - _需求：5.1, 5.2_

  - [ ] 5.2 实现费率档位测试（高/中/低）
    - 实现 `test_highFee_lowVolume()`：执行小额 swap（< 10 ether），通过读取 `poolVolumes` 或事件验证费率 == `HIGH_FEE`（10000）
    - 实现 `test_midFee_midVolume()`：执行中等 swap（≥ 10 ether，< 100 ether），验证费率 == `MID_FEE`（3000）
    - 实现 `test_lowFee_highVolume()`：执行大额 swap（≥ 100 ether），验证费率 == `LOW_FEE`（500）
    - _需求：5.3, 5.4, 5.5_

  - [ ] 5.3 实现时间窗口重置测试
    - 实现 `test_volumeReset_afterTimeWindow()`：
      1. 执行 swap 累积 volume 至中等档位
      2. 调用 `vm.warp(block.timestamp + 3601)` 推进时间
      3. 执行新的小额 swap
      4. 验证 `poolVolumes[poolId].cumulativeVolume` 已重置（仅含本次 swap 量）
      5. 验证费率恢复为 `HIGH_FEE`
    - _需求：2.6, 5.6_

  - [ ]* 5.4 为时间窗口重置编写属性测试（属性 4）
    - **属性 4：时间窗口到期后 volume 重置为零**
    - 使用 Foundry fuzzing（`testFuzz_volumeReset(uint256 timeElapsed)`，约束 `timeElapsed > TIME_WINDOW`）验证：
      - 任意超过 TIME_WINDOW 的时间推进后，下一次 `beforeSwap` 将 `cumulativeVolume` 重置为零
      - `lastResetTimestamp` 更新为当前 `block.timestamp`
    - **验证：需求 2.6, 5.6**

  - [ ] 5.5 实现 `VolumeUpdated` 事件测试
    - 实现 `test_volumeUpdated_event()`：
      1. 使用 `vm.expectEmit(true, false, false, true)` 设置事件期望
      2. 执行 swap
      3. 验证 `VolumeUpdated` 事件的 `poolId`、`newVolume`、`currentFee` 字段均与预期一致
    - _需求：2.9, 5.7_

  - [ ]* 5.6 为事件字段一致性编写属性测试（属性 5）
    - **属性 5：VolumeUpdated 事件字段与状态一致**
    - 使用 Foundry fuzzing（`testFuzz_volumeUpdatedEvent(int128 amountSpecified)`）验证：
      - 事件中 `newVolume == poolVolumes[poolId].cumulativeVolume`
      - 事件中 `currentFee == _computeFee(newVolume)`（通过公开常量推导）
    - **验证：需求 2.9, 5.7**

  - [ ] 5.7 实现非 PoolManager 调用回滚测试
    - 实现 `test_revert_notPoolManager()`：
      1. 使用 `vm.prank(address(0xdead))` 切换调用者
      2. 直接调用 `hook.beforeSwap(...)` 
      3. 使用 `vm.expectRevert(abi.encodeWithSelector(Hooks.NotPoolManager.selector))` 验证回滚
    - _需求：2.10, 5.8_

  - [ ]* 5.8 为访问控制编写属性测试（属性 6）
    - **属性 6：非 PoolManager 调用者始终被拒绝**
    - 使用 Foundry fuzzing（`testFuzz_revert_notPoolManager(address caller)`，约束 `caller != address(manager)`）验证：
      - 任意非 PoolManager 地址调用 `beforeSwap` 或 `afterSwap` 均回滚并携带 `NotPoolManager()` 错误
      - 合约状态（`cumulativeVolume`、`lastResetTimestamp`）不发生变化
    - **验证：需求 2.10, 5.8**

  - [ ] 5.9 实现测试账户代币转账测试
    - 实现 `test_tokenTransfer_betweenAccounts()`：
      1. 使用 `vm.addr(1)`、`vm.addr(2)` 创建两个测试账户 `alice` 和 `bob`
      2. 使用 `deal()` 或 `MockERC20.mint()` 为 `alice` 铸造 100 ether 的 token0 和 token1
      3. 记录转账前 `alice` 和 `bob` 的 token0 余额
      4. 使用 `vm.prank(alice)` 模拟 `alice` 调用 `token0.transfer(bob, 10 ether)`
      5. 验证 `alice` 的 token0 余额减少 10 ether
      6. 验证 `bob` 的 token0 余额增加 10 ether
      7. 验证 token0 总供应量不变
    - 实现 `test_tokenTransfer_insufficientBalance_reverts()`：
      1. 创建余额为零的测试账户 `charlie`
      2. 使用 `vm.expectRevert` 验证 `charlie` 转账时回滚
    - _需求：5.2（测试账户初始化）_

  - [ ] 5.10 实现测试账户余额查询测试
    - 实现 `test_tokenBalance_afterMint()`：
      1. 使用 `vm.addr(3)` 创建测试账户 `dave`
      2. 铸造指定数量的 token0 和 token1 给 `dave`
      3. 验证 `token0.balanceOf(dave)` 和 `token1.balanceOf(dave)` 与铸造量一致
    - 实现 `test_tokenBalance_afterSwap()`：
      1. 记录测试账户 swap 前的 token0 和 token1 余额
      2. 执行一笔 swap（token0 → token1）
      3. 验证 token0 余额减少（已支出）
      4. 验证 token1 余额增加（已收到）
      5. 验证两种代币的余额变化量之比符合当前费率下的预期兑换比例（允许一定误差）
    - 实现 `test_tokenBalance_afterLiquidityAdd()`：
      1. 创建新测试账户 `eve`，铸造足量代币
      2. 记录添加流动性前的余额
      3. 通过 Router 添加流动性
      4. 验证 `eve` 的 token0 和 token1 余额均减少（代币已存入池中）
    - _需求：5.2（测试账户初始化）_

- [ ] 6. 最终检查点 —— 全量测试验证
  - 执行 `forge test -vv`，确保所有测试通过，无任何失败或跳过。如有问题，请向用户反馈并修复。

---

## 备注

- 标有 `*` 的子任务为可选项，可在 MVP 阶段跳过以加快进度
- 每个任务均引用具体需求编号，便于追溯
- 检查点任务确保增量验证，避免错误积累
- 属性测试（Foundry fuzzing）验证普遍正确性，单元测试验证具体示例和边界条件
- Hook 地址挖矿（HookMiner）可能耗时较长，测试环境中可适当限制搜索范围
- `DYNAMIC_FEE_FLAG` 需从 `v4-core` 的 `LPFeeLibrary` 导入，确保 PoolKey 正确声明动态费率模式

## 任务依赖关系图

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2"] },
    { "id": 2, "tasks": ["2.1"] },
    { "id": 3, "tasks": ["2.2"] },
    { "id": 4, "tasks": ["2.3", "2.4"] },
    { "id": 5, "tasks": ["2.5", "2.6", "2.7"] },
    { "id": 6, "tasks": ["4.1"] },
    { "id": 7, "tasks": ["4.2"] },
    { "id": 8, "tasks": ["4.3", "5.1"] },
    { "id": 9, "tasks": ["5.2", "5.3", "5.5", "5.7"] },
    { "id": 10, "tasks": ["5.4", "5.6", "5.8"] },
    { "id": 11, "tasks": ["5.9", "5.10"] }
  ]
}
```
