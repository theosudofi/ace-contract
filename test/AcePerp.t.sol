// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TestBase } from "./TestBase.sol";
import { AcePerp } from "../src/AcePerp.sol";
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
    uint32 marketId;

    function setUp() external {
        vm.warp(1_000_000);
        token = new MockERC20("USD Coin", "USDC", 6);
        collateralOracle = new MockPriceAdapter(1e18, block.timestamp);
        indexOracle = new MockPriceAdapter(2_000e18, block.timestamp);
        router = new OracleRouter(address(this));
        router.setAssetConfig(USDC, _oracle(address(collateralOracle), false));
        router.setAssetConfig(ETH, _oracle(address(indexOracle), true));
        core = new AcePerp(address(this), address(this), address(token), USDC, address(router));
        AcePerp.MarketConfig memory c = AcePerp.MarketConfig({
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
        PriceImpactModel.Config memory impact =
            PriceImpactModel.Config(false, 1, 0, 0, 0.1e18, 0.05e18);
        marketId = core.createMarket(ETH, c, impact);
        token.mint(address(this), 2_000_000e6);
        token.approve(address(core), type(uint256).max);
        core.depositLiquidity(marketId, true, 500_000e6, 0);
        core.depositLiquidity(marketId, false, 100_000e6, 0);
        token.mint(trader, 100_000e6);
        vm.prank(trader);
        token.approve(address(core), type(uint256).max);
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

    function _open() private returns (uint256 id) {
        vm.prank(trader);
        id = core.openPosition(marketId, 2_000e6, 10_000e18, true, 2_100e18);
    }

    function testIsolatedLongShortPoolsAndTransferableShares() external {
        (address longPool, address shortPool) = core.getMarketPools(marketId);
        assertTrue(longPool != shortPool);
        assertEq(token.balanceOf(longPool), 500_000e6);
        assertEq(token.balanceOf(shortPool), 100_000e6);
        uint256 amount = MarketPoolToken(longPool).balanceOf(address(this)) / 10;
        MarketPoolToken(longPool).transfer(trader, amount);
        assertEq(MarketPoolToken(longPool).balanceOf(trader), amount);
    }

    function testMarketTokenPriceIncludesPositionPnl() external {
        _open();
        uint256 beforePrice = core.marketTokenPrice(marketId, true);
        indexOracle.setPrice(2_200e18, block.timestamp);
        uint256 afterPrice = core.marketTokenPrice(marketId, true);
        assertTrue(afterPrice < beforePrice);
    }

    function testBorrowingAccrualIncreasesPoolNavAndReducesEquity() external {
        uint256 id = _open();
        (int256 beforeEquity,) = core.positionEquityUsd(id);
        uint256 beforeNav = core.marketPoolNavUsd(marketId, true);
        vm.warp(block.timestamp + 1 days);
        (int256 afterEquity,) = core.positionEquityUsd(id);
        uint256 afterNav = core.marketPoolNavUsd(marketId, true);
        assertTrue(afterEquity < beforeEquity);
        assertTrue(afterNav > beforeNav);
    }

    function testIncreaseAndCollateralLifecycle() external {
        uint256 id = _open();
        vm.prank(trader);
        core.addCollateral(id, 1_000e6);
        vm.prank(trader);
        core.increasePosition(id, 1_000e6, 5_000e18, 2_100e18);
        (,,, uint256 collateral, uint256 sizeUsd,,,) = core.positions(id);
        assertEq(sizeUsd, 15_000e18);
        assertTrue(collateral > 3_900e6);
        vm.prank(trader);
        core.withdrawCollateral(id, 100e6);
    }

    function testPartialCloseEnforcesMinimumRemainingSize() external {
        uint256 id = _open();
        vm.prank(trader);
        vm.expectRevert(AcePerp.InvalidAmount.selector);
        core.decreasePosition(id, 9_500e18, 1_900e18);
        vm.prank(trader);
        core.decreasePosition(id, 5_000e18, 1_900e18);
        (,,,, uint256 remaining,,,) = core.positions(id);
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
            2_000e6,
            10_000e18,
            2_100e18,
            2_100e18,
            uint64(block.timestamp + 1 days)
        );
        AceOrderManager.OracleUpdate[] memory updates = new AceOrderManager.OracleUpdate[](0);
        uint256 id = manager.executeOrder(orderId, updates);
        (address owner,,,,,,,) = core.positions(id);
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
            100e6,
            1_000e18,
            2_100e18,
            2_100e18,
            uint64(block.timestamp + 1 hours)
        );
        vm.warp(block.timestamp + 2 hours);
        manager.cancelExpired(orderId);
        assertEq(token.balanceOf(trader), balanceBefore);

        uint256 positionId = _open();
        vm.prank(trader);
        vm.expectRevert(AceOrderManager.InvalidOrder.selector);
        manager.createOrder(
            AceOrderManager.OrderType.StopLoss,
            marketId + 1,
            positionId,
            true,
            0,
            1_000e18,
            1_800e18,
            1_700e18,
            uint64(block.timestamp + 1 days)
        );
    }
}
