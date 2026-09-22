// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TestBase } from "./TestBase.sol";
import { PriceData } from "../src/interfaces/IPriceAdapter.sol";
import { OracleRouter } from "../src/oracles/OracleRouter.sol";
import { MockPriceAdapter } from "./mocks/MockPriceAdapter.sol";

contract OracleRouterTest is TestBase {
    bytes32 constant ETH = bytes32("ETH");
    OracleRouter router;
    MockPriceAdapter primary;
    MockPriceAdapter secondary;

    function setUp() external {
        vm.warp(1_000_000);
        router = new OracleRouter(address(this));
        primary = new MockPriceAdapter(2_000e18, block.timestamp);
        secondary = new MockPriceAdapter(2_001e18, block.timestamp);
        router.setAssetConfig(ETH, _config());
    }

    function _config() private view returns (OracleRouter.AssetConfig memory) {
        return OracleRouter.AssetConfig({
            primary: address(primary),
            secondary: address(secondary),
            maxDeviationBps: 100,
            maxHistoricalDeviationBps: 500,
            historicalDeviationWindow: 1 hours,
            mode: OracleRouter.Mode.PrimaryWithFallback,
            enabled: true,
            requireMarketOpen: true
        });
    }

    function testReturnsBidAskAndFallback() external {
        primary.setPriceData(1_999e18, 2_001e18, block.timestamp, true);
        PriceData memory p = router.getPrice(ETH, 60);
        assertEq(p.minPrice, 1_999e18);
        primary.setShouldRevert(true);
        p = router.getPrice(ETH, 60);
        assertEq(p.minPrice, 2_001e18);
    }

    function testBindsPriceToOrderSubmission() external {
        vm.expectRevert(OracleRouter.PricePredatesOrder.selector);
        router.getPriceForAction(ETH, 60, block.timestamp + 1);
    }

    function testHistoricalCircuitBreaker() external {
        router.getPriceForAction(ETH, 60, 0);
        primary.setPrice(2_500e18, block.timestamp);
        secondary.setPrice(2_500e18, block.timestamp);
        vm.expectPartialRevert(OracleRouter.HistoricalDeviation.selector);
        router.getPriceForAction(ETH, 60, 0);
    }

    function testMarketStatus() external {
        primary.setPriceData(2_000e18, 2_000e18, block.timestamp, false);
        secondary.setPriceData(2_000e18, 2_000e18, block.timestamp, false);
        vm.expectRevert(OracleRouter.MarketClosed.selector);
        router.getPriceForAction(ETH, 60, 0);
    }
}
