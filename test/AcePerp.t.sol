// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TestBase } from "./TestBase.sol";
import { AcePerp } from "../src/AcePerp.sol";
import { PerpStore } from "../src/PerpStore.sol";
import { PoolLogic } from "../src/PoolLogic.sol";
import { TradeLogic } from "../src/TradeLogic.sol";
import { AceOrderManager } from "../src/AceOrderManager.sol";
import { MarketPoolToken } from "../src/market/MarketPoolToken.sol";
import { OracleRouter } from "../src/oracles/OracleRouter.sol";
import { PriceImpactModel } from "../src/libraries/PriceImpactModel.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPriceAdapter } from "./mocks/MockPriceAdapter.sol";

contract AcePerpTest is TestBase {
    bytes32 constant USDC = bytes32("USDC");
    bytes32 constant ETH = bytes32("ETH");
    address trader = address(0xBEEF);
    MockERC20 token;
    MockPriceAdapter collateralOracle;
    MockPriceAdapter indexOracle;
    OracleRouter router;
    AcePerp core;
    AceOrderManager orders;
    uint32 poolId;
    uint32 marketId;

    function setUp() external {
        vm.warp(1_000_000);
        token = new MockERC20("USD Coin", "USDC", 6);
        collateralOracle = new MockPriceAdapter(1e18, block.timestamp);
        indexOracle = new MockPriceAdapter(2_000e18, block.timestamp);
        router = new OracleRouter(address(this));
        router.setAssetConfig(USDC, _oracle(address(collateralOracle), false));
        router.setAssetConfig(ETH, _oracle(address(indexOracle), true));
        core = new AcePerp(
            address(this),
            address(this),
            address(router),
            address(new PoolLogic()),
            address(new TradeLogic())
        );
        PerpStore.CollateralAsset[] memory assets = new PerpStore.CollateralAsset[](1);
        assets[0] = PerpStore.CollateralAsset({ token: address(token), assetId: USDC });
        poolId = core.createPool(assets, 7 days);
        marketId = core.createMarket(poolId, ETH, _marketConfig(), _impact());
        token.mint(address(this), 2_000_000e6);
        token.approve(address(core), type(uint256).max);
        core.depositLiquidity(poolId, address(token), 600_000e6, 0);
        orders = new AceOrderManager(address(this), address(core), 0);
        core.setOrderManager(address(orders));
        token.mint(trader, 100_000e6);
        vm.startPrank(trader);
        token.approve(address(core), type(uint256).max);
        token.approve(address(orders), type(uint256).max);
        vm.stopPrank();
    }

    function _oracle(address adapter, bool requireOpen)
        private
        pure
        returns (OracleRouter.AssetConfig memory)
    {
        return OracleRouter.AssetConfig({
            primary: adapter,
            secondary: address(0),
            maxDeviationBps: 0,
            maxHistoricalDeviationBps: 5_000,
            historicalDeviationWindow: 1 hours,
            mode: OracleRouter.Mode.PrimaryOnly,
            enabled: true,
            requireMarketOpen: requireOpen
        });
    }

    function _marketConfig() private pure returns (PerpStore.MarketConfig memory) {
        return PerpStore.MarketConfig({
            maxOiUsd: 1_000_000e18,
            minPositionSizeUsd: 1_000e18,
            maxLeverageWad: 20e18,
            maxOpenPriceAge: 7 days,
            maxClosePriceAge: 7 days,
            maxLiquidationPriceAge: 1 days,
            maintenanceMarginWad: 0.05e18,
            tradeFeeWad: 0.001e18,
            liquidationFeeWad: 0.01e18,
            borrowingFactorPerSecondWad: 1e10,
            reserveFactorWad: 0.1e18
        });
    }

    function _impact() private pure returns (PriceImpactModel.Config memory) {
        return PriceImpactModel.Config(false, 1, 0, 0, 0.1e18, 0.05e18);
    }

    function _open() private returns (uint256 id) {
        id = _marketOpen(marketId, address(token), 2_000e6, 10_000e18, true, 2_100e18);
    }

    function _marketOpen(
        uint32 id,
        address collateral,
        uint256 amount,
        uint256 size,
        bool isLong,
        uint256 acceptable
    ) private returns (uint256 positionId) {
        AceOrderManager manager = AceOrderManager(core.orderManager());
        vm.prank(trader);
        uint256 orderId = manager.openPosition(
            id, collateral, amount, size, isLong, acceptable, uint64(block.timestamp + 1 days)
        );
        AceOrderManager.OracleUpdate[] memory updates = new AceOrderManager.OracleUpdate[](0);
        positionId = manager.executeOrder(orderId, updates);
    }

    function _marketDecrease(uint256 id, uint256 size, uint256 acceptable) private {
        AceOrderManager manager = AceOrderManager(core.orderManager());
        vm.prank(trader);
        uint256 orderId =
            manager.decreasePosition(id, size, acceptable, uint64(block.timestamp + 1 days));
        AceOrderManager.OracleUpdate[] memory updates = new AceOrderManager.OracleUpdate[](0);
        manager.executeOrder(orderId, updates);
    }

    function testSharedVaultHoldsBothDirections() external {
        address vault = core.getPoolVault(poolId);
        assertEq(token.balanceOf(vault), 600_000e6);
        _open();
        _marketOpen(marketId, address(token), 2_000e6, 10_000e18, false, 1_900e18);
        assertTrue(token.balanceOf(vault) > 600_000e6);
        uint256 amount = MarketPoolToken(vault).balanceOf(address(this)) / 10;
        MarketPoolToken(vault).transfer(trader, amount);
        assertEq(MarketPoolToken(vault).balanceOf(trader), amount);
    }

    function testLpPriceIgnoresOpenPnl() external {
        _open();
        uint256 beforePrice = core.poolTokenPrice(poolId);
        indexOracle.setPrice(2_200e18, block.timestamp);
        uint256 afterPrice = core.poolTokenPrice(poolId);
        assertEq(afterPrice, beforePrice);
    }

    function testLpPnlFundingChargesTheWinningSide() external {
        core.setFundingConfig(marketId, 2, 0.1e18, 0.01e18, 1);
        uint256 id = _open();
        indexOracle.setPrice(2_200e18, block.timestamp);
        collateralOracle.setPrice(1e18, block.timestamp);
        (int256 markedEquity,) = core.positionEquityUsd(id);
        uint256 beforeNav = core.poolNavUsd(poolId);
        vm.warp(block.timestamp + 1 days);
        (int256 afterEquity,) = core.positionEquityUsd(id);
        uint256 afterNav = core.poolNavUsd(poolId);
        assertTrue(afterEquity < markedEquity);
        assertTrue(afterNav > beforeNav);
        assertTrue(afterNav - beforeNav < 100e18);
    }

    function testWithdrawCannotSpendAnotherVault() external {
        bytes32 usdgId = bytes32("USDG");
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        router.setAssetConfig(
            usdgId, _oracle(address(new MockPriceAdapter(1e18, block.timestamp)), false)
        );
        PerpStore.CollateralAsset[] memory assets = new PerpStore.CollateralAsset[](2);
        assets[0] = PerpStore.CollateralAsset({ token: address(token), assetId: USDC });
        assets[1] = PerpStore.CollateralAsset({ token: address(usdg), assetId: usdgId });
        uint32 shared = core.createPool(assets, 7 days);
        usdg.mint(address(this), 10_000e6);
        usdg.approve(address(core), type(uint256).max);
        core.depositLiquidity(shared, address(token), 10_000e6, 0);
        uint256 usdgShares = core.depositLiquidity(shared, address(usdg), 10_000e6, 0);
        uint256 tokenShares =
            MarketPoolToken(core.getPoolVault(shared)).balanceOf(address(this)) - usdgShares;
        vm.expectRevert(PerpStore.ExceedsVaultValue.selector);
        core.withdrawLiquidity(shared, address(token), tokenShares + usdgShares, 0);
    }

    function testProfitIsCappedByReservedEscrow() external {
        uint256 id = _open();
        (,,,,, uint256 reserved,,,,,) = core.positions(id);
        assertTrue(reserved > 0 && reserved < 2_000e6);
        indexOracle.setPrice(2_800e18, block.timestamp);
        collateralOracle.setPrice(1e18, block.timestamp);
        uint256 traderBefore = token.balanceOf(trader);
        (uint256 liquidityBefore,,,,,,,) = core.tokenVaults(poolId, address(token));
        _marketDecrease(id, 10_000e18, 2_700e18);
        uint256 paid = token.balanceOf(trader) - traderBefore;
        assertTrue(paid < reserved + 2_000e6 + 1);
        (uint256 liquidityAfter,,,,,,,) = core.tokenVaults(poolId, address(token));
        assertTrue(liquidityAfter + 2_000e6 > liquidityBefore);
    }

    function testBorrowingAccrualIncreasesPoolNavAndReducesEquity() external {
        core.setReservingFee(poolId, address(token), 0.05e18);
        uint256 id = _open();
        (int256 beforeEquity,) = core.positionEquityUsd(id);
        uint256 beforeNav = core.poolNavUsd(poolId);
        vm.warp(block.timestamp + 1 days);
        (int256 afterEquity,) = core.positionEquityUsd(id);
        uint256 afterNav = core.poolNavUsd(poolId);
        assertTrue(afterEquity < beforeEquity);
        assertTrue(afterNav > beforeNav);
    }

    function testIncreaseAndCollateralLifecycle() external {
        uint256 id = _open();
        vm.prank(trader);
        core.addCollateral(id, 1_000e6);
        vm.prank(trader);
        core.increasePosition(id, 1_000e6, 5_000e18, 2_100e18);
        (,,,, uint256 collateral,, uint256 sizeUsd,,,,) = core.positions(id);
        assertEq(sizeUsd, 15_000e18);
        assertTrue(collateral > 3_900e6);
        vm.prank(trader);
        core.withdrawCollateral(id, 100e6);
    }

    function testPartialCloseEnforcesMinimumRemainingSize() external {
        uint256 id = _open();
        AceOrderManager manager = AceOrderManager(core.orderManager());
        vm.prank(trader);
        uint256 tooSmall =
            manager.decreasePosition(id, 9_500e18, 1_900e18, uint64(block.timestamp + 1 days));
        AceOrderManager.OracleUpdate[] memory updates = new AceOrderManager.OracleUpdate[](0);
        vm.expectRevert(PerpStore.InvalidAmount.selector);
        manager.executeOrder(tooSmall, updates);
        _marketDecrease(id, 5_000e18, 1_900e18);
        (,,,,,, uint256 remaining,,,,) = core.positions(id);
        assertEq(remaining, 5_000e18);
    }

    function testLimitOrderExecutionAndEscrow() external {
        AceOrderManager manager = new AceOrderManager(address(this), address(core), 0);
        core.setOrderManager(address(manager));
        vm.prank(trader);
        token.approve(address(manager), type(uint256).max);
        vm.prank(trader);
        uint256 orderId = manager.createOrder(
            AceOrderManager.OrderType.LimitIncrease,
            marketId,
            0,
            true,
            address(token),
            2_000e6,
            10_000e18,
            2_100e18,
            2_100e18,
            uint64(block.timestamp + 1 days)
        );
        AceOrderManager.OracleUpdate[] memory updates = new AceOrderManager.OracleUpdate[](0);
        uint256 id = manager.executeOrder(orderId, updates);
        (address owner,,,,,,,,,,) = core.positions(id);
        assertTrue(owner == trader);
    }

    function testOrderCancellationExpiryAndPositionBinding() external {
        AceOrderManager manager = new AceOrderManager(address(this), address(core), 0);
        core.setOrderManager(address(manager));
        vm.prank(trader);
        token.approve(address(manager), type(uint256).max);
        uint256 balanceBefore = token.balanceOf(trader);
        vm.prank(trader);
        uint256 orderId = manager.createOrder(
            AceOrderManager.OrderType.LimitIncrease,
            marketId,
            0,
            true,
            address(token),
            100e6,
            1_000e18,
            2_100e18,
            2_100e18,
            uint64(block.timestamp + 1 days)
        );
        vm.prank(trader);
        manager.cancelOrder(orderId);
        assertEq(token.balanceOf(trader), balanceBefore);

        vm.prank(trader);
        orderId = manager.createOrder(
            AceOrderManager.OrderType.LimitIncrease,
            marketId,
            0,
            true,
            address(token),
            100e6,
            1_000e18,
            2_100e18,
            2_100e18,
            uint64(block.timestamp + 1 hours)
        );
        vm.warp(block.timestamp + 2 hours);
        manager.cancelExpired(orderId);
        assertEq(token.balanceOf(trader), balanceBefore);
        indexOracle.setPrice(2_000e18, block.timestamp);
        collateralOracle.setPrice(1e18, block.timestamp);

        uint256 positionId = _open();
        vm.prank(trader);
        vm.expectRevert(AceOrderManager.InvalidOrder.selector);
        manager.createOrder(
            AceOrderManager.OrderType.StopLoss,
            marketId + 1,
            positionId,
            true,
            address(0),
            0,
            1_000e18,
            1_800e18,
            1_700e18,
            uint64(block.timestamp + 1 days)
        );
    }

    function testPoolAcceptsEitherCollateralAndOneMarket() external {
        bytes32 nvdaId = bytes32("NVDA");
        bytes32 usdgId = bytes32("USDG");
        MockERC20 nvda = new MockERC20("NVIDIA", "NVDA", 18);
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        router.setAssetConfig(
            nvdaId, _oracle(address(new MockPriceAdapter(180e18, block.timestamp)), true)
        );
        router.setAssetConfig(
            usdgId, _oracle(address(new MockPriceAdapter(1e18, block.timestamp)), false)
        );

        PerpStore.CollateralAsset[] memory assets = new PerpStore.CollateralAsset[](2);
        assets[0] = PerpStore.CollateralAsset({ token: address(nvda), assetId: nvdaId });
        assets[1] = PerpStore.CollateralAsset({ token: address(usdg), assetId: usdgId });
        uint32 sharedPool = core.createPool(assets, 7 days);
        uint32 nvdaMarket = core.createMarket(sharedPool, nvdaId, _marketConfig(), _impact());
        bytes32 aaplId = bytes32("AAPL");
        router.setAssetConfig(
            aaplId, _oracle(address(new MockPriceAdapter(220e18, block.timestamp)), true)
        );
        uint32 aaplMarket = core.createMarket(sharedPool, aaplId, _marketConfig(), _impact());
        assertEq(core.poolMarketCount(sharedPool), 2);
        assertTrue(core.poolMarketId(sharedPool, 0) == nvdaMarket);
        assertTrue(core.poolMarketId(sharedPool, 1) == aaplMarket);

        nvda.mint(address(this), 1_000e18);
        usdg.mint(address(this), 500_000e6);
        nvda.approve(address(core), type(uint256).max);
        usdg.approve(address(core), type(uint256).max);
        core.depositLiquidity(sharedPool, address(nvda), 1_000e18, 0);
        core.depositLiquidity(sharedPool, address(usdg), 200_000e6, 0);

        nvda.mint(trader, 100e18);
        usdg.mint(trader, 50_000e6);
        vm.startPrank(trader);
        nvda.approve(address(core), type(uint256).max);
        nvda.approve(address(orders), type(uint256).max);
        usdg.approve(address(core), type(uint256).max);
        usdg.approve(address(orders), type(uint256).max);
        vm.stopPrank();
        uint256 nvdaPosition =
            _marketOpen(nvdaMarket, address(nvda), 20e18, 10_000e18, true, 200e18);
        uint256 usdgPosition =
            _marketOpen(nvdaMarket, address(usdg), 2_000e6, 10_000e18, true, 200e18);
        _marketOpen(aaplMarket, address(usdg), 2_000e6, 10_000e18, true, 250e18);
        address vault = core.getPoolVault(sharedPool);
        assertTrue(nvda.balanceOf(vault) > 0);
        assertTrue(usdg.balanceOf(vault) > 0);

        (,,, address nvdaCollateral,,,,,,,) = core.positions(nvdaPosition);
        (,,, address usdgCollateral,,,,,,,) = core.positions(usdgPosition);
        assertTrue(nvdaCollateral == address(nvda));
        assertTrue(usdgCollateral == address(usdg));
        vm.prank(trader);
        uint256 rejected = orders.openPosition(
            marketId,
            address(usdg),
            2_000e6,
            10_000e18,
            true,
            2_100e18,
            uint64(block.timestamp + 1 days)
        );
        AceOrderManager.OracleUpdate[] memory updates = new AceOrderManager.OracleUpdate[](0);
        vm.expectRevert(PerpStore.UnsupportedCollateral.selector);
        orders.executeOrder(rejected, updates);
    }

    function testOpenInterestFundingMovesValueBetweenSides() external {
        PerpStore.MarketConfig memory config = _marketConfig();
        config.borrowingFactorPerSecondWad = 0;
        core.setMarketConfig(marketId, config);
        core.setFundingConfig(marketId, 1, 0.05e18, 0.01e18, 1);
        uint256 longId = _open();
        uint256 shortId = _marketOpen(marketId, address(token), 2_000e6, 2_000e18, false, 1_900e18);
        (int256 longBefore,) = core.positionEquityUsd(longId);
        (int256 shortBefore,) = core.positionEquityUsd(shortId);
        vm.warp(block.timestamp + 1 days);
        (int256 longAfter,) = core.positionEquityUsd(longId);
        (int256 shortAfter,) = core.positionEquityUsd(shortId);
        assertTrue(longAfter < longBefore);
        assertTrue(shortAfter > shortBefore);
    }

    function testImbalanceFeeReducesSharesWhenADepositWorsensWeight() external {
        bytes32 usdgId = bytes32("USDG");
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        router.setAssetConfig(
            usdgId, _oracle(address(new MockPriceAdapter(1e18, block.timestamp)), false)
        );
        PerpStore.CollateralAsset[] memory assets = new PerpStore.CollateralAsset[](2);
        assets[0] = PerpStore.CollateralAsset({ token: address(token), assetId: USDC });
        assets[1] = PerpStore.CollateralAsset({ token: address(usdg), assetId: usdgId });
        uint32 shared = core.createPool(assets, 7 days);
        usdg.mint(address(this), 100_000e6);
        usdg.approve(address(core), type(uint256).max);
        core.depositLiquidity(shared, address(token), 10_000e6, 0);
        core.depositLiquidity(shared, address(usdg), 10_000e6, 0);
        core.setImbalanceFee(0.05e18);
        address vault = core.getPoolVault(shared);
        uint256 supply = MarketPoolToken(vault).totalSupply();
        uint256 balanced = core.depositLiquidity(shared, address(usdg), 1_000e6, 0);
        core.depositLiquidity(shared, address(token), 1_000e6, 0);
        uint256 skewed = core.depositLiquidity(shared, address(token), 5_000e6, 0);
        assertTrue(skewed < balanced * 5);
        assertTrue(MarketPoolToken(vault).totalSupply() > supply);
    }

    function testSwapExchangesCollateralWithoutMintingShares() external {
        bytes32 usdgId = bytes32("USDG");
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        router.setAssetConfig(
            usdgId, _oracle(address(new MockPriceAdapter(1e18, block.timestamp)), false)
        );
        PerpStore.CollateralAsset[] memory assets = new PerpStore.CollateralAsset[](2);
        assets[0] = PerpStore.CollateralAsset({ token: address(token), assetId: USDC });
        assets[1] = PerpStore.CollateralAsset({ token: address(usdg), assetId: usdgId });
        uint32 shared = core.createPool(assets, 7 days);
        usdg.mint(address(this), 50_000e6);
        token.mint(address(this), 50_000e6);
        usdg.approve(address(core), type(uint256).max);
        core.depositLiquidity(shared, address(token), 20_000e6, 0);
        core.depositLiquidity(shared, address(usdg), 20_000e6, 0);
        address vault = core.getPoolVault(shared);
        uint256 supply = MarketPoolToken(vault).totalSupply();
        uint256 out = core.swap(shared, address(token), address(usdg), 1_000e6, 900e6);
        assertTrue(out >= 900e6);
        assertEq(MarketPoolToken(vault).totalSupply(), supply);
        assertEq(token.balanceOf(vault), 21_000e6);
    }

    function testKeeperAllowlistRestrictsExecution() external {
        address keeper = address(0xA11CE);
        orders.addKeeper(keeper);
        vm.prank(trader);
        uint256 orderId = orders.openPosition(
            marketId,
            address(token),
            2_000e6,
            10_000e18,
            true,
            2_100e18,
            uint64(block.timestamp + 1 days)
        );
        AceOrderManager.OracleUpdate[] memory updates = new AceOrderManager.OracleUpdate[](0);
        vm.expectRevert(AceOrderManager.UnauthorizedCaller.selector);
        orders.executeOrder(orderId, updates);
        vm.prank(keeper);
        uint256 id = orders.executeOrder(orderId, updates);
        (address owner,,,,,,,,,,) = core.positions(id);
        assertTrue(owner == trader);
    }

    function testLossProtectionSkimsLossesAndFundsWins() external {
        address vault = address(0x1055);
        token.mint(vault, 50_000e6);
        vm.prank(vault);
        token.approve(address(core), type(uint256).max);
        core.setLossProtection(vault, 1_000, 1_000);
        uint256 id = _open();
        indexOracle.setPrice(1_800e18, block.timestamp);
        collateralOracle.setPrice(1e18, block.timestamp);
        uint256 before = token.balanceOf(vault);
        _marketDecrease(id, 10_000e18, 1_700e18);
        assertTrue(token.balanceOf(vault) > before);

        id = _open();
        indexOracle.setPrice(2_200e18, block.timestamp);
        uint256 funded = token.balanceOf(vault);
        uint256 traderBefore = token.balanceOf(trader);
        _marketDecrease(id, 10_000e18, 2_100e18);
        assertTrue(token.balanceOf(vault) < funded);
        assertTrue(token.balanceOf(trader) > traderBefore);
    }

    function testFunctionMaskAndMigration() external {
        assertTrue(core.version() == 1);
        core.setFunctionMask(type(uint256).max ^ (uint256(1) << core.FN_SWAP()));
        bytes32 usdgId = bytes32("USDG");
        MockERC20 usdg = new MockERC20("Global Dollar", "USDG", 6);
        router.setAssetConfig(
            usdgId, _oracle(address(new MockPriceAdapter(1e18, block.timestamp)), false)
        );
        PerpStore.CollateralAsset[] memory assets = new PerpStore.CollateralAsset[](2);
        assets[0] = PerpStore.CollateralAsset({ token: address(token), assetId: USDC });
        assets[1] = PerpStore.CollateralAsset({ token: address(usdg), assetId: usdgId });
        uint32 shared = core.createPool(assets, 7 days);
        usdg.mint(address(this), 10_000e6);
        usdg.approve(address(core), type(uint256).max);
        core.depositLiquidity(shared, address(token), 5_000e6, 0);
        core.depositLiquidity(shared, address(usdg), 5_000e6, 0);
        vm.expectRevert();
        core.swap(shared, address(token), address(usdg), 100e6, 0);
        core.migrate(2, type(uint256).max);
        assertTrue(core.version() == 2);
        assertTrue(core.swap(shared, address(token), address(usdg), 100e6, 0) > 0);
    }
}
