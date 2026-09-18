// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable2Step } from "../access/Ownable2Step.sol";
import { IPriceAdapter } from "../interfaces/IPriceAdapter.sol";
import { MathX } from "../libraries/MathX.sol";

/// @notice Asset-to-adapter registry with optional cross-oracle validation and fallback.
contract OracleRouter is Ownable2Step {
    enum Mode {
        PrimaryOnly,
        PrimaryWithFallback,
        RequireBoth
    }

    struct AssetConfig {
        address primary;
        address secondary;
        uint16 maxDeviationBps;
        Mode mode;
        bool enabled;
    }

    error InvalidOracleConfig();
    error AssetDisabled(bytes32 assetId);
    error NoValidPrice(bytes32 assetId);
    error PriceDeviation(bytes32 assetId, uint256 primaryPrice, uint256 secondaryPrice);

    mapping(bytes32 assetId => AssetConfig) public configs;

    event AssetConfigured(
        bytes32 indexed assetId,
        address indexed primary,
        address indexed secondary,
        Mode mode,
        uint16 maxDeviationBps,
        bool enabled
    );

    constructor(address initialOwner) Ownable2Step(initialOwner) { }

    function setAssetConfig(bytes32 assetId, AssetConfig calldata config) external onlyOwner {
        if (
            assetId == bytes32(0) || config.primary == address(0) || config.primary.code.length == 0
                || config.maxDeviationBps > 5_000
                || (config.mode != Mode.PrimaryOnly
                    && (config.secondary == address(0) || config.secondary.code.length == 0))
        ) revert InvalidOracleConfig();
        configs[assetId] = config;
        emit AssetConfigured(
            assetId,
            config.primary,
            config.secondary,
            config.mode,
            config.maxDeviationBps,
            config.enabled
        );
    }

    /// @return priceWad USD price normalized to 18 decimals.
    function getPrice(bytes32 assetId, uint256 maxAge)
        external
        view
        returns (uint256 priceWad, uint256 updatedAt)
    {
        AssetConfig memory config = configs[assetId];
        if (!config.enabled) revert AssetDisabled(assetId);

        (bool primaryOk, uint256 primaryPrice, uint256 primaryTime) =
            _tryRead(config.primary, maxAge);
        if (config.mode == Mode.PrimaryOnly) {
            if (!primaryOk) revert NoValidPrice(assetId);
            return (primaryPrice, primaryTime);
        }

        (bool secondaryOk, uint256 secondaryPrice, uint256 secondaryTime) =
            _tryRead(config.secondary, maxAge);
        if (config.mode == Mode.RequireBoth && (!primaryOk || !secondaryOk)) {
            revert NoValidPrice(assetId);
        }
        if (!primaryOk && !secondaryOk) revert NoValidPrice(assetId);
        if (!primaryOk) return (secondaryPrice, secondaryTime);
        if (!secondaryOk) return (primaryPrice, primaryTime);

        uint256 difference = primaryPrice > secondaryPrice
            ? primaryPrice - secondaryPrice
            : secondaryPrice - primaryPrice;
        uint256 deviationBps = MathX.mulDiv(difference, 10_000, primaryPrice);
        if (deviationBps > config.maxDeviationBps) {
            revert PriceDeviation(assetId, primaryPrice, secondaryPrice);
        }

        // The configured primary remains authoritative; the secondary is a circuit breaker.
        return (primaryPrice, primaryTime < secondaryTime ? primaryTime : secondaryTime);
    }

    function _tryRead(address adapter, uint256 maxAge)
        private
        view
        returns (bool ok, uint256 price, uint256 timestamp)
    {
        try IPriceAdapter(adapter).getPrice(maxAge) returns (uint256 p, uint256 t) {
            if (
                p != 0 && p <= uint256(type(int256).max) && t != 0 && t <= block.timestamp
                    && block.timestamp - t <= maxAge
            ) {
                return (true, p, t);
            }
        } catch { }
        return (false, 0, 0);
    }
}
