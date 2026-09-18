// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TestBase } from "./TestBase.sol";
import { OracleRouter } from "../src/oracles/OracleRouter.sol";
import { MockPriceAdapter } from "./mocks/MockPriceAdapter.sol";

contract OracleRouterTest is TestBase {
    bytes32 internal constant ETH = bytes32("ETH");
    OracleRouter internal router;
    MockPriceAdapter internal primary;
    MockPriceAdapter internal secondary;

    function setUp() external {
        vm.warp(1_000_000);
        router = new OracleRouter(address(this));
        primary = new MockPriceAdapter(2_000e18, block.timestamp);
        secondary = new MockPriceAdapter(2_001e18, block.timestamp);
        router.setAssetConfig(
            ETH,
            OracleRouter.AssetConfig({
                primary: address(primary),
                secondary: address(secondary),
                maxDeviationBps: 100,
                mode: OracleRouter.Mode.PrimaryWithFallback,
                enabled: true
            })
        );
    }

    function testUsesPrimaryWhenSourcesAgree() external view {
        (uint256 price,) = router.getPrice(ETH, 60);
        assertEq(price, 2_000e18);
    }

    function testFallsBackWhenPrimaryFails() external {
        primary.setShouldRevert(true);
        (uint256 price,) = router.getPrice(ETH, 60);
        assertEq(price, 2_001e18);
    }

    function testRejectsLargeDeviation() external {
        secondary.setPrice(2_100e18, block.timestamp);
        vm.expectPartialRevert(OracleRouter.PriceDeviation.selector);
        router.getPrice(ETH, 60);
    }

    function testRejectsStaleSources() external {
        vm.warp(block.timestamp + 120);
        vm.expectPartialRevert(OracleRouter.NoValidPrice.selector);
        router.getPrice(ETH, 60);
    }
}
