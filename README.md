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
