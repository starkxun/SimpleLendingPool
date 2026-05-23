# SimpleLendingPool — 教学用借贷协议

## 项目结构

```
src/
├── LendingPool.sol     ← 核心逻辑（存/借/还/清算 + 利率模型）
├── LToken.sol          ← 存款凭证代币（类比 cToken）
├── MockERC20.sol       ← 测试用代币
└── interfaces/
    └── IERC20.sol

test/
└── LendingPool.t.sol   ← 完整 Foundry 测试套件（7 个模块）
```

## 快速开始

```bash
forge build
forge test -vv          # 运行所有测试，显示 console.log
forge test -vvvv        # 显示完整调用栈（调试用）
forge test --match-test test_FullBorrowRepay -vv   # 单测
```

---

## 核心机制详解

## 项目公式总表（按代码实现整理）

以下公式全部对应 `src/LendingPool.sol` 的实际实现，单位精度默认是 WAD(1e18) 或 RAY(1e27)。

### 0. 精度与常量

- `WAD = 1e18`
- `RAY = 1e27`
- `SECONDS_PER_YEAR = 365 days`
- `OPTIMAL_UTILIZATION = 0.8e18`
- `LTV = 0.75e18`
- `LIQUIDATION_THRESHOLD = 0.8e18`
- `LIQUIDATION_BONUS = 0.05e18`
- `COLLATERAL_PRICE = 2e18`

### 1. 利用率与利率

1. 资金利用率

```text
u = totalBorrows / (cash + totalBorrows)
实现：u = (totalBorrows * WAD) / (cash + totalBorrows)
```

2. 借款年化利率（分段线性 Kink Model）

```text
if u <= optimal:
  borrowRate = BASE_RATE + SLOPE1 * u
else:
  borrowRate = BASE_RATE + SLOPE1 * optimal + SLOPE2 * (u - optimal)

实现中所有乘法都要 /WAD 做缩放还原
```

补充：`SLOPE1` 的含义（你问到的重点）

```text
SLOPE1 = 0.125e18（WAD）
表示在利用率 0% -> 80% 区间内，利用率每增加 100%，借款年化利率增加 12.5%。
```

该值来自设计目标：

```text
BASE_RATE = 2%
u = 80% 时目标利率 = 12%

2% + SLOPE1 * 80% = 12%
=> SLOPE1 = (12% - 2%) / 80% = 10% / 0.8 = 12.5%
```

直观例子：

```text
u = 40%: borrowRate = 2% + 12.5% * 0.4 = 7%
u = 80%: borrowRate = 2% + 12.5% * 0.8 = 12%
```

3. 存款年化利率（忽略 reserve factor）

```text
supplyRate = borrowRate * u
实现：supplyRate = (borrowRate * u) / WAD
```

### 2. 借款指数与总借款

1. 全局 borrowIndex 更新（线性近似）

```text
elapsed = now - lastAccrualTimestamp
interestFactor = annualRate * elapsed / SECONDS_PER_YEAR
newBorrowIndex = oldBorrowIndex * (1 + interestFactor)

实现：newBorrowIndex = borrowIndex + (borrowIndex * interestFactor) / WAD
```

2. 协议总借款（当前时点）

```text
totalBorrows = totalBorrowPrincipal * borrowIndex / RAY
```

3. 标准化本金定义

```text
principal(normalized) = actualDebt * RAY / borrowIndex
```

4. 用户当前债务（含 pending 利息）

```text
pendingIndex = borrowIndex + borrowIndex * pendingInterestFactor
userDebt = userPrincipal * pendingIndex / RAY
```

5. borrowIndex 的直觉含义

```text
borrowIndex 是“全局累计债务倍率”。
初始 borrowIndex = RAY（即 1.0 倍）。
随着时间推移和计息，borrowIndex 只会逐步增大。
```

```text
用户债务不是直接存当前金额，而是读取时再还原：
debtNow = principal * borrowIndexNow / RAY
```

6. interestFactor 是什么，和 borrowIndex 什么关系

```text
interestFactor = annualRate * elapsed / SECONDS_PER_YEAR
```

```text
interestFactor 表示“本次时间片利息比例”（增量）。
borrowIndex 表示“历史累计后的总倍率”（存量）。
```

```text
二者关系：
newBorrowIndex = oldBorrowIndex + oldBorrowIndex * interestFactor / WAD
              = oldBorrowIndex * (1 + interestFactor / WAD)
```

7. 为什么要存标准化本金 principal（而不是直接存当前债务）

```text
标准化：principal = debtAtAction * RAY / borrowIndexAtAction
还原：  debtNow    = principal * borrowIndexNow / RAY
```

这样做的意义：

```text
不需要给每个用户逐个写利息；
只更新一次全局 borrowIndex，所有用户债务在读取时自动反映累计利息。
```

8. 完整数值例子（借款 -> 计息 -> 还款后再标准化）

```text
初始：borrowIndex = 1.00（RAY）
用户借款：100
=> principal = 100 / 1.00 = 100

一段时间后：interestFactor = 10%
=> borrowIndex = 1.00 * (1 + 10%) = 1.10

此时债务：debtNow = 100 * 1.10 = 110

若用户还款 30：
newDebt = 110 - 30 = 80
newPrincipal = 80 / 1.10 = 72.7272...

后续继续计息时，只需要让 borrowIndex 继续增长，
再用 debt = principal * latestIndex / RAY 还原即可。
```

### 3. 存款凭证（lToken）与汇率

1. 汇率（exchangeRate）

```text
pendingTotalBorrows = totalBorrowPrincipal * pendingIndex / RAY
totalAssets = cash + pendingTotalBorrows
exchangeRate = totalAssets / lTokenSupply

实现：exchangeRate = (totalAssets * WAD) / lTokenSupply
当 lTokenSupply = 0 时，exchangeRate = 1e18
```

2. 存款铸造 lToken

```text
lTokenMinted = depositAmount / exchangeRate
实现：lTokenMinted = (depositAmount * WAD) / exchangeRate
```

3. 赎回底层资产

```text
underlyingReturned = lTokenAmount * exchangeRate
实现：underlyingReturned = (lTokenAmount * exchangeRate) / WAD
```

### 4. 借款与还款

1. 借款后总债务

```text
newDebt = existingDebt + borrowAmount
```

2. 借款后新标准化本金

```text
newPrincipal = newDebt * RAY / borrowIndex
```

3. 全局标准化本金更新（借款/还款/清算都同样模式）

```text
totalBorrowPrincipal = totalBorrowPrincipal - oldUserPrincipal + newUserPrincipal
```

4. 还款实际扣款

```text
repayAmount = min(inputAmount, debt)
newDebt = debt - repayAmount
newPrincipal = newDebt * RAY / borrowIndex
```

5. 当前实现中的利息事件口径

```text
interest = max(0, repayAmount - currentPrincipalValue)
其中 currentPrincipalValue = oldPrincipal * borrowIndex / RAY
```

### 5. 抵押物风控

1. 抵押物价值折算（按 borrowAsset 计价）

```text
collateralValueInBorrow = collateralAmount * COLLATERAL_PRICE
实现：collateralValueInBorrow = (collateralAmount * COLLATERAL_PRICE) / WAD
```

2. 最大可借额度（LTV）

```text
maxBorrowable = collateralValueInBorrow * LTV
实现：maxBorrowable = (collateralValueInBorrow * LTV) / WAD
```

3. 清算阈值价值

```text
thresholdValue = collateralValueInBorrow * LIQUIDATION_THRESHOLD
实现：thresholdValue = (collateralValueInBorrow * LIQUIDATION_THRESHOLD) / WAD
```

4. 健康因子

```text
healthFactor = thresholdValue / debt
实现：healthFactor = (thresholdValue * WAD) / debt
判定：healthFactor >= WAD 安全；< WAD 可清算
```

### 6. 清算公式

1. 清算可获得抵押物

```text
collateralValue = repayAmount / COLLATERAL_PRICE
实现：collateralValue = (repayAmount * WAD) / COLLATERAL_PRICE

collateralSeized = collateralValue * (1 + LIQUIDATION_BONUS)
实现：collateralSeized = collateralValue + (collateralValue * LIQUIDATION_BONUS) / WAD
```

2. 清算后债务更新

```text
newDebt = oldDebt - repayAmount
newPrincipal = newDebt * RAY / borrowIndex
```

### 1. lToken（存款凭证）

类比 Compound 的 cToken、Aave 的 aToken。

```
存款时：lTokenMinted = depositAmount / exchangeRate
取款时：underlying  = lTokenAmount * exchangeRate

exchangeRate = (poolCash + totalBorrows) / lTokenTotalSupply
```

随着借款人支付利息，`totalBorrows` 增大 → `exchangeRate` 上升 → 
持有相同 lToken 能换回更多 underlying。**这是存款人获得利息的机制。**

### 2. borrowIndex（利息累积指数）

Compound V2 的核心设计，解决「高效更新所有人债务」的问题。

```solidity
// 每隔 Δt 秒，全局更新一次
borrowIndex(t) = borrowIndex(t-1) * (1 + rate * Δt)

// 用户实际债务（随时计算，无需遍历）
actualDebt = userNormalizedPrincipal * borrowIndex(now) / RAY
```

**借款时**：记录快照 `{ principal = debt/borrowIndex*RAY, interestIndex = borrowIndex }`  
**还款时**：`actualDebt = principal * borrowIndex_now / RAY`，利息 = actualDebt - originalDebt

### 3. 利率模型（Kink Model）

```
APR
112%│                              ╱
    │                            ╱
 12%│            ╱──────────────╱   ← slope2（陡）
    │          ╱
  2%│─────────╱                     ← slope1（缓）
    └──────────┬──────────────────── utilization
              80%                100%
```

设计意图：高利用率时利率急剧上升，激励存款人进入并威慑借款人，
防止池子流动性耗尽。

### 4. 健康因子与清算

```
healthFactor = collateralValue * liquidationThreshold / totalDebt
             = (10 WETH * 2 USDC/WETH) * 80% / 15 USDC
             = 16 / 15 ≈ 1.067  →  安全

当 HF < 1：任何人可以调用 liquidate()
清算人还清部分债务，获得等值抵押物 + 5% 奖励（liquidation bonus）
```

---

## 审计关注点（对照生产协议时的差异）

| 特性 | 本教学合约 | 生产协议（如 Compound V2）|
|------|-----------|------------------------|
| 价格来源 | 硬编码常量 | Chainlink Oracle |
| 利息计算 | 线性近似 | 精确复利（指数函数） |
| Reserve Factor | 0（无协议收益） | 通常 10-20% |
| 清算上限 | 可还全部债务 | close factor（通常 50%）|
| 多资产 | 单资产对 | 多资产、跨池 |
| Reentrancy 防护 | 无（教学用） | ReentrancyGuard |
| 精度 | WAD/RAY 混用 | 严格一致 |

## 常见漏洞复现位置（审计练习）

1. **Price Oracle 操纵** → `COLLATERAL_PRICE` 固定，生产中需用 TWAP
2. **借款上限绕过** → `borrow()` 中的 LTV 检查是否可以通过重入绕过？
3. **清算奖励计算** → `collateralSeized` 的精度截断是否有利可图？
4. **accrue 顺序** → 如果调用前不 accrue，`borrowIndex` 是否过时？
5. **整数溢出** → `totalBorrowPrincipal` 的加减是否对称？

---

## 学习建议：借贷项目 vs 质押项目

### 这两类项目有什么区别？

1. 资金关系不同

- 借贷协议：有存款人、借款人、清算人，核心是“负债管理 + 利息累计 + 风险控制”。
- 质押协议：用户锁定资产获取奖励，核心是“锁仓状态 + 奖励分发 + 解锁机制”。

2. 收益来源不同

- 借贷协议：收益主要来自借款人支付的利息。
- 质押协议：收益主要来自通胀奖励、手续费分成或验证者收益。

3. 风险类型不同

- 借贷协议：坏账风险、清算失败、参数失衡、预言机问题。
- 质押协议：解锁挤兑、奖励参数失衡、罚没（slashing）、流动性质押脱锚。

4. 核心指标不同

- 借贷协议：Utilization、BorrowRate、borrowIndex、LTV、Health Factor。
- 质押协议：APR/APY、锁仓期、解锁窗口、罚没率、节点收益表现。

### 质押项目要不要单独学？

建议单独学。两者都涉及“份额”和“收益累计”，但状态机与风险模型差异较大。

- 借贷侧重点：债务随时间增长、清算阈值、流动性管理。
- 质押侧重点：锁仓与解锁生命周期、奖励发放节奏、罚没与安全性。

### 推荐学习顺序（基于本项目）

1. 先把借贷闭环彻底吃透（本项目）

- 利率模型（低区间/高区间）
- borrowIndex 与标准化本金 principal
- 健康因子、LTV、清算流程
- exchangeRate 如何把利息分配给存款人

2. 再做一个最小质押项目

- stake / unstake / claimReward
- 设计奖励累计变量（如 rewardPerToken）
- 处理锁仓期、提前退出罚金（可选）

3. 最后做对照复盘

- 借贷项目看“债务增长 + 清算保护”
- 质押项目看“奖励增长 + 锁仓约束”
- 对比两者的份额模型与精度处理（WAD/RAY）

### 一句话结论

本项目是非常好的借贷入门实战；质押建议作为下一阶段单独学习模块来做，这样成长路径最稳、理解也最深。

### 面向合约审计实习的补充建议

如果你的目标岗位是合约审计，最优策略不是二选一，而是“官方项目为主 + 最小自写项目为辅”。

1. 要不要单独完整做一个质押项目？

- 不建议一开始就做大而全项目。
- 建议至少完成一个最小可运行质押协议（stake / unstake / claim），用于建立审计视角。

2. 能不能直接学现成官方项目？

- 可以，而且非常推荐。
- 官方项目能快速建立你对真实生产架构、权限分层、经济参数与治理流程的理解。

3. 为什么要“官方 + 自写”组合？

- 只看官方：容易停留在“看懂流程”，但不一定能快速定位漏洞与边界条件。
- 只做自写：能练手，但缺少真实协议中的复杂依赖与工程细节。
- 组合学习：既能对齐工业实践，也能形成可落地的审计思维。

4. 推荐优先学习的官方方向（审计价值高）

- Synthetix `StakingRewards`：奖励分发与 `rewardPerToken` 模型。
- Lido：流动性质押与份额/赎回关系。
- Rocket Pool：节点运营与质押机制。
- 对照借贷协议（Compound/Aave）：强化 index 与份额模型的迁移理解。

5. 两周实操路线（审计导向）

- 第 1 周：精读一个官方质押实现，画状态机和资金流，列出至少 10 个风险点。
- 第 2 周：自写最小质押合约，并补齐 8-12 个审计向测试（权限、重入、精度、时间边界、奖励计算）。

6. 最终目标

- 不是“会写合约”而已，而是能快速建立不变量、识别攻击面、解释风险路径并给出修复建议。
