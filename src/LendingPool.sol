// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SimpleLendingPool — 教学用简易借贷协议
 *
 * ┌─────────────────────────────────────────────────────────────┐
 * │  核心机制概览                                                  │
 * │                                                             │
 * │  1. 存款 (deposit)   → 铸造 lToken（生息凭证）                  │
 * │  2. 取款 (withdraw)  → 销毁 lToken，拿回本金+利息               │
 * │  3. 借款 (borrow)    → 抵押物 → 借出资产，记录 borrowIndex 快照  │
 * │  4. 还款 (repay)     → 归还本金+累计利息                        │
 * │  5. 清算 (liquidate) → 健康因子 < 1 时，第三方代还并获奖励        │
 * │                                                             │
 * │  利率模型：分段线性（低于 optimal 斜率缓，超过后斜率陡）             │
 * │  利息计算：borrowIndex 累积法（参考 Compound V2）               │
 * └─────────────────────────────────────────────────────────────┘
 *
 * 简化假设（与生产协议的差异）：
 *  - 只支持单一资产对（collateral token / borrow token）
 *  - 价格固定（生产中应接 oracle）
 *  - 没有协议收益分成（reserve factor = 0）
 *  - 没有跨链、没有闪电贷
 */

import {IERC20} from "./interfaces/IERC20.sol";
import {LToken} from "./LToken.sol";

contract LendingPool {
    // ═══════════════════════════════════════════════════════════
    //  常量与配置
    // ═══════════════════════════════════════════════════════════

    /// @dev WAD = 1e18，用于定点数乘除
    uint256 public constant WAD = 1e18;
    /// @dev RAY = 1e27，用于高精度利率累积
    uint256 public constant RAY = 1e27;
    /// @dev 每年的秒数（近似值）
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // ── 利率模型参数（分段线性）────────────────────────────────────
    /// @dev 最优利用率（80%），低于此点斜率较缓
    uint256 public constant OPTIMAL_UTILIZATION = 0.80e18; // 80%
    /// @dev 基础利率：年化 2%
    uint256 public constant BASE_RATE = 0.02e18;
    /// @dev 低区间斜率：利用率 0→80% 时，利率从 2% 升至 12%
    // 在利用率 u∈[0,80%] 这段里，利用率每上升 1（即 100%），借款年化利率增加 12.5 个百分点
    uint256 public constant SLOPE1 = 0.125e18; // (10% / 80%)
    /// @dev 高区间斜率：利用率 80%→100% 时，利率从 12% 急升至 112%
    uint256 public constant SLOPE2 = 5.0e18;   // (100% / 20%)

    // ── 风险参数 ──────────────────────────────────────────────
    /// @dev LTV（Loan-To-Value）= 75%，抵押 100 最多借 75
    uint256 public constant LTV = 0.75e18;
    /// @dev 清算阈值 = 80%，健康因子 = 抵押价值*80% / 负债
    uint256 public constant LIQUIDATION_THRESHOLD = 0.80e18;
    /// @dev 清算奖励（bonus）= 5%，清算人额外获得 5% 抵押物
    uint256 public constant LIQUIDATION_BONUS = 0.05e18;
    /// @dev 抵押物价格（固定，生产中用 oracle）1 collateral = 2 borrowToken
    uint256 public constant COLLATERAL_PRICE = 2e18;

    // ═══════════════════════════════════════════════════════════
    //  状态变量
    // ═══════════════════════════════════════════════════════════

    /// @dev 可借出的资产（如 USDC）
    IERC20 public immutable borrowAsset;
    /// @dev 抵押物资产（如 WETH）
    IERC20 public immutable collateralAsset;
    /// @dev 存款凭证 token（lToken，类似 Compound 的 cToken）
    LToken public immutable lToken;

    /// @notice 全局借款利率累积指数，初始 = RAY（1e27）
    /// @dev    Compound V2 核心机制：borrowIndex 记录「自协议启动以来」的累积利息倍数
    ///         每次有人操作时，先 accrue()，再用新 index 结算
    uint256 public borrowIndex = RAY;

    /// @notice 上次 accrue 的时间戳
    uint256 public lastAccrualTimestamp;

    /// @notice 协议内总借款本金（以当前 borrowIndex 的 principal 单位计）
    ///         totalBorrows = Σ (用户借款额 / 借款时的 borrowIndex * RAY)
    uint256 public totalBorrowPrincipal;

    // ── 用户级数据 ─────────────────────────────────────────────

    struct BorrowSnapshot {
        uint256 principal;      // 用户借款时记录的「标准化本金」= actual / borrowIndex * RAY
        uint256 interestIndex;  // 借款时的 borrowIndex 快照
    }

    /// @dev 用户借款快照
    mapping(address => BorrowSnapshot) public borrows;
    /// @dev 用户抵押物余额
    mapping(address => uint256) public collateralBalance;

    // ═══════════════════════════════════════════════════════════
    //  事件
    // ═══════════════════════════════════════════════════════════

    event Deposit(address indexed user, uint256 amount, uint256 lTokensMinted);
    event Withdraw(address indexed user, uint256 lTokensBurned, uint256 amountReturned);
    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount, uint256 borrowIndex);
    event Repay(address indexed user, uint256 repaid, uint256 interest);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 repaidDebt,
        uint256 collateralSeized
    );
    event AccrueInterest(
        uint256 borrowIndex,
        uint256 interestAccumulated,
        uint256 totalBorrows
    );

    // ═══════════════════════════════════════════════════════════
    //  构造函数
    // ═══════════════════════════════════════════════════════════

    constructor(
        address _borrowAsset,
        address _collateralAsset,
        address _lToken
    ) {
        borrowAsset = IERC20(_borrowAsset);
        collateralAsset = IERC20(_collateralAsset);
        lToken = LToken(_lToken);
        lastAccrualTimestamp = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════
    //  利率模型
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice 计算当前借款年化利率（APR）
     * @dev 分段线性利率模型（Kink Model）
     *
     *  APR
     *  112% │                                    ╱
     *       │                                  ╱
     *   12% │                    ╱────────────╱  ← slope2（很陡）
     *        │               ╱
     *    2%  │──────────────╱                    ← slope1（较缓）
     *        └──────────────┬──────────────────── utilization
     *                      80%                100%
     *
     * @param utilization 利用率 [0, 1e18]
     * @return rate 年化借款利率（WAD 精度）
     */
    function getBorrowRate(uint256 utilization) public pure returns (uint256 rate) {
        if (utilization <= OPTIMAL_UTILIZATION) {
            // 低区间：BASE_RATE + SLOPE1 * utilization
            // SLOPE1 是每单位利用率对应的利率斜率，直接乘 utilization 再除 WAD
            rate = BASE_RATE + (SLOPE1 * utilization) / WAD;
        } else {
            // 高区间：(kink 点利率) + SLOPE2 * (超出部分利用率)
            uint256 excessUtil = utilization - OPTIMAL_UTILIZATION;
            rate = BASE_RATE + (SLOPE1 * OPTIMAL_UTILIZATION) / WAD + (SLOPE2 * excessUtil) / WAD;
        }
    }

    /**
     * @notice 计算存款年化利率（供参考，lToken 汇率变化体现利息）
     * @dev supplyRate = borrowRate * utilization（忽略 reserve factor）
     */
    function getSupplyRate() public view returns (uint256) {
        uint256 u = getUtilization();
        return (getBorrowRate(u) * u) / WAD;
    }

    /**
     * @notice 当前资金利用率 = totalBorrows / (totalBorrows + 池中余额)
     */
    function getUtilization() public view returns (uint256) {
        uint256 cash = borrowAsset.balanceOf(address(this));
        uint256 totalBorrows = getTotalBorrows();
        if (cash + totalBorrows == 0) return 0;
        return (totalBorrows * WAD) / (cash + totalBorrows);
    }

    /**
     * @notice 将标准化本金还原为当前实际借款额
     * @dev    actualDebt = principal * borrowIndex / RAY
     */
    function getTotalBorrows() public view returns (uint256) {
        return (totalBorrowPrincipal * borrowIndex) / RAY;
    }

    // ═══════════════════════════════════════════════════════════
    //  利息累积（Accrue Interest）
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice 核心：将累积利息写入 borrowIndex
     *
     * @dev 机制说明（Compound V2 风格）：
     *
     *  borrowIndex(t) = borrowIndex(t-1) * (1 + rate * Δt)
     *
     *  为什么用 index 而不是直接记利息？
     *  → 效率：无需遍历所有用户，O(1) 完成全局更新
     *  → 用户实际负债 = userPrincipal * borrowIndex(now) / borrowIndex(snapshot)
     *
     *  每次存/取/借/还/清算前都必须先调用此函数，保证 index 是最新的。
     */
    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        uint256 utilization = getUtilization(); // 获取资金利用率
        uint256 annualRate = getBorrowRate(utilization);    // 获取借款年化率

        // 线性近似：适合短间隔；生产协议用复利（exponentiation）
        // interestFactor = rate * elapsed / SECONDS_PER_YEAR
        uint256 interestFactor = (annualRate * elapsed) / SECONDS_PER_YEAR;

        // 新 borrowIndex = 旧 index * (1 + interestFactor)
        uint256 newBorrowIndex = borrowIndex + (borrowIndex * interestFactor) / WAD;

        uint256 interestAccumulated = getTotalBorrows();
        borrowIndex = newBorrowIndex;
        uint256 newTotalBorrows = getTotalBorrows();

        lastAccrualTimestamp = block.timestamp;
        emit AccrueInterest(borrowIndex, newTotalBorrows - interestAccumulated, newTotalBorrows);
    }

    // ═══════════════════════════════════════════════════════════
    //  存款 / 取款
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice 存入 borrowAsset，铸造 lToken
     *
     * @dev lToken 是「资金池份额」凭证，类似 Compound 的 cToken：
     *
     *  exchangeRate = (poolCash + totalBorrows) / lTokenSupply
     *  mintAmount   = depositAmount / exchangeRate
     *
     *  随着借款人支付利息，poolCash + totalBorrows 增大，
     *  exchangeRate 上升 → 持有相同 lToken 能换回更多 borrowAsset。
     *  这就是存款人赚取利息的方式。
     */
    function deposit(uint256 amount) external {
        accrueInterest();
        require(amount > 0, "amount = 0");

        uint256 mintAmount = _calcLTokenAmount(amount);
        borrowAsset.transferFrom(msg.sender, address(this), amount);
        lToken.mint(msg.sender, mintAmount);

        emit Deposit(msg.sender, amount, mintAmount);
    }

    /**
     * @notice 销毁 lToken，取回 borrowAsset（含利息）
     */
    function withdraw(uint256 lTokenAmount) external {
        accrueInterest();
        require(lTokenAmount > 0, "amount = 0");

        uint256 returnAmount = _calcUnderlyingAmount(lTokenAmount);
        require(borrowAsset.balanceOf(address(this)) >= returnAmount, "insufficient liquidity");

        lToken.burn(msg.sender, lTokenAmount);
        borrowAsset.transfer(msg.sender, returnAmount);

        emit Withdraw(msg.sender, lTokenAmount, returnAmount);
    }

    // ── lToken 汇率计算 ──────────────────────────────────────
    // supply: lToken 总发行量
    // totalAssets： 池子的总资产价值（按borrowAssets计价，不包含抵押物资产）
    function exchangeRate() public view returns (uint256) {
        uint256 supply = lToken.totalSupply();
        if (supply == 0) return WAD; // 初始 1:1
        uint256 pendingIndex = _pendingBorrowIndex();
        uint256 pendingTotalBorrows = (totalBorrowPrincipal * pendingIndex) / RAY;
        uint256 totalAssets = borrowAsset.balanceOf(address(this)) + pendingTotalBorrows;
        return (totalAssets * WAD) / supply;
    }

    function _calcLTokenAmount(uint256 underlyingAmount) internal view returns (uint256) {
        return (underlyingAmount * WAD) / exchangeRate();
    }

    function _calcUnderlyingAmount(uint256 lTokenAmount) internal view returns (uint256) {
        return (lTokenAmount * exchangeRate()) / WAD;
    }

    // ═══════════════════════════════════════════════════════════
    //  抵押物管理
    // ═══════════════════════════════════════════════════════════

    function depositCollateral(uint256 amount) external {
        require(amount > 0, "amount = 0");
        collateralAsset.transferFrom(msg.sender, address(this), amount);
        collateralBalance[msg.sender] += amount;
        emit DepositCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external {
        accrueInterest();
        require(collateralBalance[msg.sender] >= amount, "insufficient collateral");

        // 取出后检查健康因子
        collateralBalance[msg.sender] -= amount;
        require(_isHealthy(msg.sender), "would be undercollateralized");

        collateralAsset.transfer(msg.sender, amount);
        emit WithdrawCollateral(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  借款 / 还款
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice 借出 borrowAsset
     *
     * @dev borrowIndex 快照机制：
     *
     *  借款时记录：snapshot.interestIndex = borrowIndex(now)
     *  还款时计算：actualDebt = snapshot.principal * borrowIndex(now) / snapshot.interestIndex
     *
     *  例：borrowIndex=1.0 时借 100，借款人 principal=100，interestIndex=1.0
     *      1 年后 borrowIndex=1.1（利率 10%），actualDebt = 100 * 1.1 / 1.0 = 110
     */
    function borrow(uint256 amount) external {
        accrueInterest();
        require(amount > 0, "amount = 0");
        require(borrowAsset.balanceOf(address(this)) >= amount, "insufficient liquidity");

        // 计算用户已有债务，合并为新的标准化 principal
        uint256 existingDebt = _getBorrowBalance(msg.sender);
        uint256 newDebt = existingDebt + amount;

        // 检查借款上限：debt ≤ collateralValue * LTV
        uint256 maxBorrow = _maxBorrowable(msg.sender);
        require(newDebt <= maxBorrow, "exceeds LTV");

        // 更新用户借款快照（标准化本金 = 实际债务 / 当前 index * RAY）
        uint256 newPrincipal = (newDebt * RAY) / borrowIndex;
        totalBorrowPrincipal = totalBorrowPrincipal
            - borrows[msg.sender].principal
            + newPrincipal;

        borrows[msg.sender] = BorrowSnapshot({
            principal: newPrincipal,
            interestIndex: borrowIndex
        });

        borrowAsset.transfer(msg.sender, amount);
        emit Borrow(msg.sender, amount, borrowIndex);
    }

    /**
     * @notice 还款（全部或部分）
     */
    function repay(uint256 amount) external {
        accrueInterest();

        uint256 debt = _getBorrowBalance(msg.sender);
        require(debt > 0, "no debt");

        uint256 repayAmount = amount > debt ? debt : amount;
        uint256 interest = repayAmount > (borrows[msg.sender].principal * borrowIndex / RAY)
            ? repayAmount - (borrows[msg.sender].principal * borrowIndex / RAY)
            : 0;

        borrowAsset.transferFrom(msg.sender, address(this), repayAmount);

        uint256 newDebt = debt - repayAmount;
        uint256 newPrincipal = (newDebt * RAY) / borrowIndex;

        totalBorrowPrincipal = totalBorrowPrincipal
            - borrows[msg.sender].principal
            + newPrincipal;

        borrows[msg.sender] = BorrowSnapshot({
            principal: newPrincipal,
            interestIndex: borrowIndex
        });

        emit Repay(msg.sender, repayAmount, interest);
    }

    // ═══════════════════════════════════════════════════════════
    //  清算
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice 清算健康因子 < 1 的账户
     *
     * @dev 清算流程：
     *  1. 检查 borrower 的健康因子 < 1（负债 > 抵押阈值价值）
     *  2. liquidator 替 borrower 还部分债务
     *  3. liquidator 获得等值抵押物 + liquidation bonus（5%）
     *
     *  清算奖励（bonus）是对清算人承担风险的补偿，也防止协议产生坏账。
     *
     * @param borrower    被清算用户
     * @param repayAmount liquidator 愿意代还的债务金额
     */
    function liquidate(address borrower, uint256 repayAmount) external {
        accrueInterest();

        require(!_isHealthy(borrower), "borrower is healthy");

        uint256 debt = _getBorrowBalance(borrower);
        require(repayAmount > 0 && repayAmount <= debt, "invalid repay amount");

        // 计算 liquidator 获得的抵押物数量
        // collateralSeized = repayAmount / COLLATERAL_PRICE * (1 + LIQUIDATION_BONUS)
        uint256 collateralValue = (repayAmount * WAD) / COLLATERAL_PRICE;
        uint256 collateralSeized = collateralValue + (collateralValue * LIQUIDATION_BONUS) / WAD;

        require(collateralBalance[borrower] >= collateralSeized, "insufficient collateral to seize");

        // 执行清算
        borrowAsset.transferFrom(msg.sender, address(this), repayAmount);
        collateralBalance[borrower] -= collateralSeized;
        collateralAsset.transfer(msg.sender, collateralSeized);

        // 更新债务
        uint256 newDebt = debt - repayAmount;
        uint256 newPrincipal = (newDebt * RAY) / borrowIndex;
        totalBorrowPrincipal = totalBorrowPrincipal
            - borrows[borrower].principal
            + newPrincipal;
        borrows[borrower] = BorrowSnapshot({
            principal: newPrincipal,
            interestIndex: borrowIndex
        });

        emit Liquidate(msg.sender, borrower, repayAmount, collateralSeized);
    }

    // ═══════════════════════════════════════════════════════════
    //  风险计算（内部）
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice 健康因子 = 抵押价值 * 清算阈值 / 总债务
     *         healthFactor >= 1e18 → 安全；< 1e18 → 可被清算
     */
    function healthFactor(address user) public view returns (uint256) {
        uint256 debt = _getBorrowBalance(user);
        if (debt == 0) return type(uint256).max; // 无债务，健康因子无穷大

        uint256 collateralValueInBorrow = (collateralBalance[user] * COLLATERAL_PRICE) / WAD;
        uint256 thresholdValue = (collateralValueInBorrow * LIQUIDATION_THRESHOLD) / WAD;

        return (thresholdValue * WAD) / debt;
    }

    function _isHealthy(address user) internal view returns (bool) {
        return healthFactor(user) >= WAD;
    }

    function _maxBorrowable(address user) internal view returns (uint256) {
        uint256 collateralValueInBorrow = (collateralBalance[user] * COLLATERAL_PRICE) / WAD;
        return (collateralValueInBorrow * LTV) / WAD;
    }

    /// @notice 预估当前 borrowIndex，用于 view 函数
    function _pendingBorrowIndex() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return borrowIndex;
        uint256 annualRate = getBorrowRate(getUtilization());
        // 把年化利率按经过时间折算成本段利息因子
        // 本次时间片的利息比例”（这一小段时间的涨幅，不是累计总涨幅）
        // 比如年化 12%，过了半年，那么 interestFactor 约等于 6%
        uint256 interestFactor = (annualRate * elapsed) / SECONDS_PER_YEAR;
        return borrowIndex + (borrowIndex * interestFactor) / WAD;
    }

    /// @notice 计算用户当前实际债务（本金 + 累积利息，含 pending 部分）
    function _getBorrowBalance(address user) internal view returns (uint256) {
        BorrowSnapshot memory snap = borrows[user];
        if (snap.principal == 0) return 0;
        // 使用 pending index，使 view 调用时也能看到未 accrue 的利息
        return (snap.principal * _pendingBorrowIndex()) / RAY;
    }

    // ═══════════════════════════════════════════════════════════
    //  View 辅助函数
    // ═══════════════════════════════════════════════════════════

    function getBorrowBalance(address user) external view returns (uint256) {
        return _getBorrowBalance(user);
    }

    function getAccountInfo(address user)
        external
        view
        returns (
            uint256 depositedLTokens,
            uint256 depositValue,
            uint256 collateral,
            uint256 debt,
            uint256 hf
        )
    {
        depositedLTokens = lToken.balanceOf(user);
        depositValue = _calcUnderlyingAmount(depositedLTokens);
        collateral = collateralBalance[user];
        debt = _getBorrowBalance(user);
        hf = healthFactor(user);
    }
}
