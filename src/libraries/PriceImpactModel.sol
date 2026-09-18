// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { MathX } from "./MathX.sol";

/// @notice Path-integrated, skew-aware execution pricing.
/// @dev A trade pays when it increases |long OI - short OI| and receives a bounded rebate when it
/// decreases it. Unlike a final-utilization spread, splitting an order does not avoid impact.
library PriceImpactModel {
    using MathX for uint256;

    uint256 internal constant WAD = 1e18;

    error InvalidImpactConfig();
    error InvalidTradeDelta();

    struct Config {
        bool enabled;
        uint8 exponent; // 1 = linear potential, 2 = quadratic potential
        uint64 baseSpreadWad;
        uint64 impactFactorWad;
        uint64 maxAdverseImpactWad;
        uint64 maxRebateWad;
    }

    struct Quote {
        uint256 executionPrice;
        int256 impactRateWad; // positive is price improvement for the trader
        uint256 spreadRateWad;
        uint256 longOiAfter;
        uint256 shortOiAfter;
    }

    function validate(Config memory config) internal pure {
        if (
            (config.exponent != 1 && config.exponent != 2) || config.baseSpreadWad > 0.1e18
                || config.impactFactorWad > 0.5e18 || config.maxAdverseImpactWad > 0.1e18
                || config.maxRebateWad > 0.05e18
        ) revert InvalidImpactConfig();
    }

    function quote(
        Config memory config,
        uint256 oraclePrice,
        uint256 longOi,
        uint256 shortOi,
        uint256 maxOi,
        uint256 sizeUsd,
        bool isLong,
        bool isIncrease
    ) internal pure returns (Quote memory result) {
        validate(config);
        if (oraclePrice == 0 || sizeUsd == 0 || maxOi == 0) revert InvalidTradeDelta();

        result.longOiAfter = longOi;
        result.shortOiAfter = shortOi;
        if (isLong) {
            if (isIncrease) {
                result.longOiAfter += sizeUsd;
            } else {
                if (sizeUsd > longOi) revert InvalidTradeDelta();
                result.longOiAfter -= sizeUsd;
            }
        } else {
            if (isIncrease) {
                result.shortOiAfter += sizeUsd;
            } else {
                if (sizeUsd > shortOi) revert InvalidTradeDelta();
                result.shortOiAfter -= sizeUsd;
            }
        }

        int256 impactRate;
        if (config.enabled && config.impactFactorWad != 0) {
            uint256 beforePotential = _potential(config, longOi, shortOi, maxOi);
            uint256 afterPotential =
                _potential(config, result.longOiAfter, result.shortOiAfter, maxOi);
            int256 impactUsd = int256(beforePotential) - int256(afterPotential);
            impactRate = impactUsd >= 0
                ? int256(MathX.mulDiv(uint256(impactUsd), WAD, sizeUsd))
                : -int256(MathX.mulDiv(uint256(-impactUsd), WAD, sizeUsd));
            int256 maxRebate = int256(uint256(config.maxRebateWad));
            int256 maxAdverse = int256(uint256(config.maxAdverseImpactWad));
            if (impactRate > maxRebate) impactRate = maxRebate;
            if (impactRate < -maxAdverse) impactRate = -maxAdverse;
        }

        // Positive adjustment is adverse. A rebate can outweigh the base spread, but is capped.
        int256 adjustment = int256(uint256(config.baseSpreadWad)) - impactRate;
        bool isBuy = isLong == isIncrease; // open long / close short buy the index
        int256 multiplier = isBuy ? int256(WAD) + adjustment : int256(WAD) - adjustment;
        if (multiplier <= 0) revert InvalidImpactConfig();

        result.executionPrice = MathX.mulDiv(oraclePrice, uint256(multiplier), WAD);
        result.impactRateWad = impactRate;
        result.spreadRateWad = config.baseSpreadWad;
    }

    function _potential(Config memory config, uint256 longOi, uint256 shortOi, uint256 maxOi)
        private
        pure
        returns (uint256)
    {
        uint256 skew = longOi > shortOi ? longOi - shortOi : shortOi - longOi;
        uint256 normalized = MathX.min(MathX.mulDiv(skew, WAD, maxOi), WAD);
        uint256 curve =
            config.exponent == 1 ? normalized : MathX.mulDiv(normalized, normalized, WAD);
        uint256 capacityValue = MathX.mulDiv(maxOi, config.impactFactorWad, WAD);
        return MathX.mulDiv(capacityValue, curve, WAD);
    }
}
