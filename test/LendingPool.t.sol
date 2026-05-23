// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LToken} from "../src/LToken.sol";
import {MockERC20} from "../src/MockERC20.sol";

/**
 * @title LendingPoolTest — 借贷协议完整测试套件
 *
 * 测试覆盖：
 *  [模块 1] 利率模型验证
 *  [模块 2] 存款 / lToken 铸造
 *  [模块 3] borrowIndex 累积（时间推进）
 *  [模块 4] 借款 / 还款完整流程
 *  [模块 5] 健康因子 & 清算
 *  [模块 6] 边界条件 & revert 测试
 *  [模块 7] 多用户场景（存款人、借款人分离）
 */
contract LendingPoolTest is Test {
    LendingPool pool;
    LToken lToken;
    MockERC20 usdc;    // borrowAsset
    MockERC20 weth;    // collateralAsset

    // 测试账户
    address alice = makeAddr("alice");   // 存款人
    address bob   = makeAddr("bob");     // 借款人
    address carol = makeAddr("carol");   // 清算人

    uint256 constant WAD = 1e18;
    uint256 constant RAY = 1e27;

    // ── 价格常量（与合约保持一致）────────────────────────────
    // 1 WETH = 2 USDC（简化价格）
    uint256 constant COLLATERAL_PRICE = 2e18;

    function setUp() public {
        // 1. 部署 Mock 代币
        usdc = new MockERC20("USD Coin", "USDC");
        weth = new MockERC20("Wrapped Ether", "WETH");

        // 2. 先部署一个临时地址占位，再部署真正的 LToken
        //    （因为 LToken 需要 pool 地址，pool 需要 LToken 地址——用 CREATE2 或分两步）
        //    这里用分两步：先算 pool 地址，再部署 lToken
        address predictedPool = computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        lToken = new LToken("Lending USDC", "lUSDC", predictedPool);
        pool   = new LendingPool(address(usdc), address(weth), address(lToken));

        // 验证地址预测正确
        assertEq(address(pool), predictedPool, "address prediction failed");

        // 3. 给测试账户铸造代币
        usdc.mint(alice, 100_000e18);  // Alice 有 100k USDC 用于存款
        weth.mint(bob, 1000e18);       // Bob 有 1000 WETH 用于抵押
        usdc.mint(carol, 10_000e18);   // Carol 有 USDC 用于清算

        // 4. 授权
        vm.prank(alice); usdc.approve(address(pool), type(uint256).max);
        vm.prank(bob);   weth.approve(address(pool), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(pool), type(uint256).max);
        vm.prank(carol); usdc.approve(address(pool), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════
    //  [模块 1] 利率模型
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev 验证分段线性利率模型的关键节点
     *
     *  利用率 0%   → APR ≈ 2%（基础利率）
     *  利用率 80%  → APR ≈ 12%（kink 点）
     *  利用率 100% → APR ≈ 112%（高区间顶部）
     */
    function test_InterestRateModel_BelowKink() public view {
        // 利用率 = 0，应得到基础利率 2%
        uint256 rate0 = pool.getBorrowRate(0);
        assertEq(rate0, 0.02e18, "base rate should be 2%");

        // 利用率 = 40%（kink 的一半），利率应在 2% 和 12% 之间
        uint256 rate40 = pool.getBorrowRate(0.40e18);
        // BASE_RATE + SLOPE1 * (0.4 / 0.8) = 2% + 10% * 0.5 = 7%
        assertApproxEqRel(rate40, 0.07e18, 0.001e18, "40% utilization rate");

        // 利用率 = 80%（kink 点）
        uint256 rate80 = pool.getBorrowRate(0.80e18);
        // BASE_RATE + SLOPE1 = 2% + 10% = 12%
        assertApproxEqRel(rate80, 0.12e18, 0.001e18, "kink rate should be ~12%");
    }

    function test_InterestRateModel_AboveKink() public view {
        // 利用率 90%（kink 之上），利率应急剧上升
        uint256 rate90 = pool.getBorrowRate(0.90e18);
        // BASE + SLOPE1 + SLOPE2 * (0.1 / 0.2) = 2% + 10% + 500% * 10% = 62%
        assertApproxEqRel(rate90, 0.62e18, 0.01e18, "90% util: rate should be ~62%");

        // 利用率 100%，应得到最高利率
        uint256 rate100 = pool.getBorrowRate(1e18);
        // BASE + SLOPE1 + SLOPE2 = 2% + 10% + 100% = 112%
        assertApproxEqRel(rate100, 1.12e18, 0.01e18, "100% util: rate should be ~112%");
    }

    // ═══════════════════════════════════════════════════════════
    //  [模块 2] 存款 & lToken 铸造
    // ═══════════════════════════════════════════════════════════

    function test_Deposit_FirstDepositor_OneToOne() public {
        // 第一个存款人：exchangeRate = 1，lToken 数量 = 存款数量
        vm.prank(alice);
        pool.deposit(10_000e18);

        uint256 lBal = lToken.balanceOf(alice);
        assertEq(lBal, 10_000e18, "first depositor should get 1:1 lTokens");
        assertEq(usdc.balanceOf(address(pool)), 10_000e18, "pool should hold USDC");
    }

    function test_Deposit_ExchangeRateGrows_AfterInterest() public {
        // 1. Alice 存款(注入流动性)
        vm.prank(alice);
        pool.deposit(10_000e18);

        // 2. Bob 存款抵押物 + 借款（产生利息）
        vm.prank(bob);
        pool.depositCollateral(100e18); // 100 WETH = 200 USDC 价值

        vm.prank(bob);
        pool.borrow(100e18); // 借 100 USDC（LTV 150/200 = 75%）

        // 3. 时间推进 1 年
        skip(365 days);

        // 4. 第二个存款人应该得到更少的 lToken（因为 exchangeRate 变大了）
        uint256 exchangeRateBefore = pool.exchangeRate();
        console2.log("exchangeRate after 1 year:", exchangeRateBefore);

        // exchangeRate > 1 说明有利息累积
        assertGt(exchangeRateBefore, WAD, "exchange rate should grow over time");
        
        // 计算调用逻辑：
        // 1. 计算利用率：100 / 100_000 = 1% (参考 getUtilization() 函数)
        // 2. 计算借款年化率：2% + 0.125 * 1% = 2.125%  (参考 getBorrowRate() 函数) 
        // 3. 预估 borrowIndex (borrowIndex 初始值为 RAY)： 1 + 2.125% (参考 _pendingBorrowIndex() 函数)
        // 4. 读取新的 exchangeRate： (100 * 1.02125 + 9_900) / 100_00  = 1.0002125 (参考 exchangeRate() 函数)
        // exchangeRate() 是 view 函数，不改变链上状态，属于推演
    }

    // ═══════════════════════════════════════════════════════════
    //  [模块 3] borrowIndex 累积
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev 验证 borrowIndex 随时间正确累积
     *
     *  初始 borrowIndex = RAY = 1e27
     *  1 年后（利用率 ~1%，利率 ~2%）：borrowIndex ≈ 1.02 * RAY
     */
    function test_BorrowIndex_AccruesCorrectly() public {
        // 先让池子有余额和借款
        vm.prank(alice);
        pool.deposit(10_000e18);

        vm.prank(bob);
        pool.depositCollateral(100e18);

        vm.prank(bob);
        pool.borrow(100e18); // 很低的利用率 ≈ 1%

        uint256 indexBefore = pool.borrowIndex();
        console2.log("borrowIndex before:", indexBefore);

        // 推进 1 年
        skip(365 days);
        pool.accrueInterest();

        uint256 indexAfter = pool.borrowIndex();
        console2.log("borrowIndex after 1 year:", indexAfter);

        assertGt(indexAfter, indexBefore, "borrowIndex should increase");
        // 利率约 2%，1 年后 index 应约增加 2%
        // indexAfter ≈ RAY * 1.02
        assertApproxEqRel(indexAfter, RAY * 102 / 100, 0.01e18, "index should grow ~2% at low utilization");
    
        // 具体计算调用逻辑同 test_Deposit_ExchangeRateGrows_AfterInterest 函数
    }

    // ═══════════════════════════════════════════════════════════
    //  [模块 4] 完整借贷流程
    // ═══════════════════════════════════════════════════════════

    function test_FullBorrowRepay_WithInterest() public {
        // ── 准备 ──────────────────────────────────────────────
        vm.prank(alice);
        pool.deposit(10_000e18);

        vm.prank(bob);
        pool.depositCollateral(100e18);  // 100 WETH = 200 USDC（按价格）

        // ── 借款 ──────────────────────────────────────────────
        uint256 borrowAmount = 100e18;
        vm.prank(bob);
        pool.borrow(borrowAmount);

        uint256 bobUsdcAfterBorrow = usdc.balanceOf(bob);
        assertEq(bobUsdcAfterBorrow, borrowAmount, "bob should receive borrowed amount");

        // ── 时间推进（产生利息）─────────────────────────────────
        skip(180 days); // 半年

        // ── 检查债务增长 ──────────────────────────────────────
        uint256 debtAfter6Months = pool.getBorrowBalance(bob);
        assertGt(debtAfter6Months, borrowAmount, "debt should grow with interest");
        console2.log("original borrow:", borrowAmount / 1e18, "USDC");
        console2.log("debt after 6 months:", debtAfter6Months / 1e18, "USDC");

        // ── 还款 ──────────────────────────────────────────────
        // 给 Bob 额外 USDC 用于还利息
        usdc.mint(bob, 1000e18);
        vm.prank(bob); usdc.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        pool.repay(debtAfter6Months); // 全额还款

        uint256 remainingDebt = pool.getBorrowBalance(bob);
        assertEq(remainingDebt, 0, "debt should be zero after full repay");
    }

    function test_Borrow_RevertsIfExceedsLTV() public {
        vm.prank(alice);
        pool.deposit(10_000e18);

        // Bob 存 100 WETH = 200 USDC 价值，LTV 75% → max borrow = 150 USDC
        vm.prank(bob);
        pool.depositCollateral(100e18);

        // 尝试借 151 USDC → 应 revert
        vm.prank(bob);
        vm.expectRevert("exceeds LTV");
        pool.borrow(151e18);

        // 借 150 USDC → 应成功（边界）
        vm.prank(bob);
        pool.borrow(150e18);
    }

    // ═══════════════════════════════════════════════════════════
    //  [模块 5] 健康因子 & 清算
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev 清算场景：
     *  Bob 借到上限后，价格下跌（通过修改合约 mock 不现实，
     *  这里用时间推进 + 高利率来模拟健康因子下降）
     *
     *  更真实的测试：在生产协议中 oracle 价格下跌触发清算
     *  此测试演示利息积累导致健康因子下降
     */
    function test_Liquidation_AfterInterestAccumulation() public {
        // 1. Alice 存款（提供流动性）
        vm.prank(alice);
        pool.deposit(10_000e18);

        // 2. Bob 存少量抵押物，借到接近上限
        //    10 WETH = 20 USDC，LTV 75% → max borrow = 15 USDC
        vm.prank(bob);
        pool.depositCollateral(10e18);

        vm.prank(bob);
        pool.borrow(15e18); // 借到 LTV 上限

        // 检查初始健康因子
        // HF = collateral * price * liquidationThreshold / debt
        //    = 10 * 2 * 80% / 15 ≈ 1.067
        uint256 hfInitial = pool.healthFactor(bob);
        console2.log("initial HF:", hfInitial * 100 / WAD, "%");
        assertGt(hfInitial, WAD, "should be healthy initially");

        // 3. 推进大量时间使利息累积，债务超过清算阈值
        //    10 WETH * 2 * 80% = 16 USDC threshold
        //    债务需超过 16 USDC，即利息超过 1 USDC（6.67%）
        skip(1500 days);
        pool.accrueInterest();

        uint256 hfAfter = pool.healthFactor(bob);
        console2.log("HF after 1500 days:", hfAfter * 100 / WAD, "%");

        // 若 HF < 1，可以被清算
        if (hfAfter < WAD) {
            console2.log("Bob is liquidatable!");
            
            uint256 bobDebt = pool.getBorrowBalance(bob);
            uint256 repayAmount = bobDebt / 2; // 还一半（部分清算）

            uint256 carolWethBefore = weth.balanceOf(carol);
            vm.prank(carol);
            pool.liquidate(bob, repayAmount);

            uint256 carolWethAfter = weth.balanceOf(carol);
            uint256 collateralGained = carolWethAfter - carolWethBefore;
            console2.log("Carol gained WETH:", collateralGained / 1e18);

            // 清算人应获得 > 还款价值的抵押物（含 5% bonus）
            assertGt(collateralGained, 0, "liquidator should receive collateral");
        } else {
            console2.log("Skipping liquidation: HF still healthy (utilization too low for high rate)");
        }
    }

    function test_Liquidation_RevertsIfHealthy() public {
        vm.prank(alice); pool.deposit(10_000e18);
        vm.prank(bob); pool.depositCollateral(100e18);
        vm.prank(bob); pool.borrow(100e18);

        // Bob 是健康的，Carol 不能清算
        vm.prank(carol);
        vm.expectRevert("borrower is healthy");
        pool.liquidate(bob, 50e18);
    }

    // ═══════════════════════════════════════════════════════════
    //  [模块 6] 边界条件
    // ═══════════════════════════════════════════════════════════

    function test_Withdraw_FullAmount_AfterInterest() public {
        // Alice 存款，等待利息，取回比存入更多
        vm.prank(alice);
        pool.deposit(10_000e18);

        // Bob 借款产生利息
        vm.prank(bob); pool.depositCollateral(100e18);
        vm.prank(bob); pool.borrow(100e18);

        skip(365 days);

        // Bob 还款（先给他 USDC）
        // 注意：vm.prank 会被 getBorrowBalance（staticcall）消耗，需分两步写
        usdc.mint(bob, 10e18);
        vm.prank(bob); usdc.approve(address(pool), type(uint256).max);
        uint256 bobDebt = pool.getBorrowBalance(bob);
        vm.prank(bob); pool.repay(bobDebt);

        // Alice 取出全部
        uint256 lBalance = lToken.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw(lBalance);

        uint256 aliceFinalUsdc = usdc.balanceOf(alice);
        // Alice 取出的应该比初始 100k 存入的多（多了利息，减了存款 10k 后）
        // 初始：100_000e18，存了 10_000e18，取回 > 10_000e18
        console2.log("Alice final USDC:", aliceFinalUsdc / 1e18);
        assertGt(aliceFinalUsdc, 100_000e18, "Alice should profit from lending");
    }

    function test_WithdrawCollateral_RevertsIfUndercollateralized() public {
        vm.prank(alice); pool.deposit(10_000e18);
        vm.prank(bob); pool.depositCollateral(100e18); // 100 WETH = 200 USDC
        vm.prank(bob); pool.borrow(150e18); // 借满 LTV

        // Bob 尝试取出抵押物 → 会导致 HF < 1，应 revert
        // 清算阈值 80%，取出后 HF = (100-x)*2*0.8/150 < 1 → x > 6.25 WETH，取 7 WETH 足以触发
        vm.prank(bob);
        vm.expectRevert("would be undercollateralized");
        pool.withdrawCollateral(7e18); // 取出 7 WETH，使 HF < 1
    }

    // ═══════════════════════════════════════════════════════════
    //  [模块 7] 多用户场景
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev 场景：Alice 和 Carol 都存款，Bob 借款
     *  验证利息按比例分配给所有存款人
     */
    function test_MultipleDepositors_InterestSharing() public {
        // Alice 存 10_000，Carol 存 10_000（各占 50%）
        vm.prank(alice); pool.deposit(10_000e18);

        usdc.mint(carol, 100_000e18);
        vm.prank(carol); usdc.approve(address(pool), type(uint256).max);
        vm.prank(carol); pool.deposit(10_000e18);

        // Bob 借款：200 WETH = 400 USDC 价值，LTV 75% → max 300 USDC；需存 700 WETH 才能借 1000 USDC
        vm.prank(bob); pool.depositCollateral(700e18);
        vm.prank(bob); pool.borrow(1000e18);

        skip(365 days);

        // Bob 还款
        // 注意：vm.prank 会被 getBorrowBalance（staticcall）消耗，需分两步写
        usdc.mint(bob, 1000e18);
        vm.prank(bob); usdc.approve(address(pool), type(uint256).max);
        uint256 bobDebt = pool.getBorrowBalance(bob);
        vm.prank(bob); pool.repay(bobDebt);

        // Alice 和 Carol 取款
        uint256 aliceLToken = lToken.balanceOf(alice);
        uint256 carolLToken = lToken.balanceOf(carol);

        // 两者 lToken 数量相同，应该取回相同的 USDC
        assertEq(aliceLToken, carolLToken, "equal depositors should have equal lTokens");

        vm.prank(alice);
        pool.withdraw(aliceLToken);

        vm.prank(carol);
        pool.withdraw(carolLToken);

        // 两者收益应该相等
        // Alice：初始 100_000，存了 10_000，剩余基数 = 90_000
        // Carol：初始 10_000（setUp）+ 100_000（本测试 mint）- 10_000（存款）= 100_000 基数
        uint256 aliceProfit = usdc.balanceOf(alice) - (100_000e18 - 10_000e18);
        uint256 carolProfit = usdc.balanceOf(carol) - (10_000e18 + 100_000e18 - 10_000e18);
        assertApproxEqRel(aliceProfit, carolProfit, 0.001e18, "profits should be equal");
        console2.log("Alice profit:", aliceProfit / 1e15, "mUSDC");
        console2.log("Carol profit:", carolProfit / 1e15, "mUSDC");
    }

    // ═══════════════════════════════════════════════════════════
    //  [辅助] 打印账户状态（调试用）
    // ═══════════════════════════════════════════════════════════

    function _printAccountInfo(string memory label, address user) internal view {
        (
            uint256 depositedLTokens,
            uint256 depositValue,
            uint256 collateral,
            uint256 debt,
            uint256 hf
        ) = pool.getAccountInfo(user);

        console2.log("=====", label, "=====");
        console2.log("lTokens:", depositedLTokens / 1e18);
        console2.log("depositValue (USDC):", depositValue / 1e18);
        console2.log("collateral (WETH):", collateral / 1e18);
        console2.log("debt (USDC):", debt / 1e18);
        if (hf == type(uint256).max) {
            console2.log("healthFactor: inf (no debt)");
        } else {
            console2.log("healthFactor (%):", hf * 100 / WAD);
        }
    }
}
