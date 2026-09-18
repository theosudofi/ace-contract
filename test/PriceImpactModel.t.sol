// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TestBase } from "./TestBase.sol";
import { PriceImpactModel } from "../src/libraries/PriceImpactModel.sol";

contract PriceImpactHarness {
    function quote(
        PriceImpactModel.Config memory config,
        uint256 oraclePrice,
        uint256 longOi,
        uint256 shortOi,
        uint256 maxOi,
        uint256 sizeUsd,
        bool isLong,
        bool isIncrease
    ) external pure returns (PriceImpactModel.Quote memory) {
        return PriceImpactModel.quote(
            config, oraclePrice, longOi, shortOi, maxOi, sizeUsd, isLong, isIncrease
        );
    }
}

contract PriceImpactModelTest is TestBase {
    PriceImpactHarness internal harness = new PriceImpactHarness();

    function config() internal pure returns (PriceImpactModel.Config memory) {
        return PriceImpactModel.Config({
            enabled: true,
            exponent: 2,
            baseSpreadWad: 0.001e18,
            impactFactorWad: 0.05e18,
            maxAdverseImpactWad: 0.1e18,
            maxRebateWad: 0.05e18
        });
    }

    function testCrowdedTradePaysAndBalancingTradeReceivesRebate() external view {
        PriceImpactModel.Quote memory crowded =
            harness.quote(config(), 2_000e18, 500_000e18, 0, 1_000_000e18, 100_000e18, true, true);
        PriceImpactModel.Quote memory balancing =
            harness.quote(config(), 2_000e18, 500_000e18, 0, 1_000_000e18, 100_000e18, false, true);

        assertTrue(crowded.impactRateWad < 0);
        assertTrue(crowded.executionPrice > 2_000e18);
        assertTrue(balancing.impactRateWad > 0);
        assertTrue(balancing.executionPrice > 2_000e18); // short sells above mark when rebate > spread
    }

    function testSplittingOrderDoesNotAvoidImpact() external view {
        uint256 price = 2_000e18;
        uint256 maxOi = 1_000_000e18;
        uint256 size = 200_000e18;
        PriceImpactModel.Quote memory whole =
            harness.quote(config(), price, 0, 0, maxOi, size, true, true);

        PriceImpactModel.Quote memory first =
            harness.quote(config(), price, 0, 0, maxOi, size / 2, true, true);
        PriceImpactModel.Quote memory second = harness.quote(
            config(), price, first.longOiAfter, first.shortOiAfter, maxOi, size / 2, true, true
        );
        uint256 splitAverage = (first.executionPrice + second.executionPrice) / 2;
        assertApproxEqAbs(whole.executionPrice, splitAverage, 2);
    }

    function testClosingLongUsesSellDirection() external view {
        PriceImpactModel.Quote memory result =
            harness.quote(config(), 2_000e18, 100_000e18, 0, 1_000_000e18, 50_000e18, true, false);
        assertTrue(result.impactRateWad > 0);
        assertTrue(result.executionPrice > 2_000e18);
    }

    function testFuzzSplittingResistance(uint96 rawSize, uint96 rawFirst) external view {
        uint256 size = (uint256(rawSize) % 400_000 + 2) * 1e18;
        uint256 firstSize = (uint256(rawFirst) % (size / 1e18 - 1) + 1) * 1e18;
        uint256 secondSize = size - firstSize;
        uint256 price = 2_000e18;
        uint256 maxOi = 1_000_000e18;

        PriceImpactModel.Quote memory whole =
            harness.quote(config(), price, 0, 0, maxOi, size, true, true);
        PriceImpactModel.Quote memory first =
            harness.quote(config(), price, 0, 0, maxOi, firstSize, true, true);
        PriceImpactModel.Quote memory second =
            harness.quote(config(), price, first.longOiAfter, 0, maxOi, secondSize, true, true);
        uint256 splitWeightedPrice =
            (first.executionPrice * firstSize + second.executionPrice * secondSize) / size;
        assertApproxEqAbs(whole.executionPrice, splitWeightedPrice, 3);
    }
}
