// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable2Step } from "../access/Ownable2Step.sol";
import { IPriceAdapter, IUpdatablePriceAdapter, PriceData } from "../interfaces/IPriceAdapter.sol";
import { MathX } from "../libraries/MathX.sol";

/// @notice Oracle quorum, timestamp binding, market-status and circuit-breaker boundary.
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
        uint16 maxHistoricalDeviationBps;
        uint32 historicalDeviationWindow;
        Mode mode;
        bool enabled;
        bool requireMarketOpen;
    }
    error InvalidOracleConfig();
    error AssetDisabled(bytes32 assetId);
    error NoValidPrice(bytes32 assetId);
    error PriceDeviation(bytes32 assetId, uint256 primaryPrice, uint256 secondaryPrice);
    error HistoricalDeviation(bytes32 assetId, uint256 oldPrice, uint256 newPrice);
    error PricePredatesOrder();
    error MarketClosed();
    error InvalidUpdateTarget();
    mapping(bytes32 => AssetConfig) public configs;
    mapping(bytes32 => uint256) public lastAcceptedMid;
    mapping(bytes32 => uint256) public lastAcceptedAt;
    event AssetConfigured(
        bytes32 indexed assetId,
        address indexed primary,
        address indexed secondary,
        Mode mode,
        uint16 maxDeviationBps,
        bool enabled
    );
    event PriceAccepted(
        bytes32 indexed assetId, uint256 minPrice, uint256 maxPrice, uint256 updatedAt
    );
    constructor(address initialOwner) Ownable2Step(initialOwner) { }

    function setAssetConfig(bytes32 assetId, AssetConfig calldata c) external onlyOwner {
        if (
            assetId == 0 || c.primary == address(0) || c.primary.code.length == 0
                || c.maxDeviationBps > 5_000 || c.maxHistoricalDeviationBps > 10_000
                || (c.mode != Mode.PrimaryOnly
                    && (c.secondary == address(0) || c.secondary.code.length == 0))
        ) revert InvalidOracleConfig();
        configs[assetId] = c;
        emit AssetConfigured(assetId, c.primary, c.secondary, c.mode, c.maxDeviationBps, c.enabled);
    }

    function updatePrice(bytes32 assetId, bool secondary, bytes calldata data) external payable {
        AssetConfig memory c = configs[assetId];
        address target = secondary ? c.secondary : c.primary;
        if (!c.enabled || target == address(0)) revert InvalidUpdateTarget();
        IUpdatablePriceAdapter(target).update{ value: msg.value }(data);
    }

    function getPrice(bytes32 assetId, uint256 maxAge) external view returns (PriceData memory) {
        return _read(assetId, maxAge);
    }

    function getPriceForAction(bytes32 assetId, uint256 maxAge, uint256 submittedAt)
        external
        returns (PriceData memory data)
    {
        AssetConfig memory c = configs[assetId];
        data = _read(assetId, maxAge);
        if (data.updatedAt < submittedAt) revert PricePredatesOrder();
        if (c.requireMarketOpen && !data.marketOpen) revert MarketClosed();
        uint256 mid = (data.minPrice + data.maxPrice) / 2;
        uint256 old = lastAcceptedMid[assetId];
        if (
            old != 0 && c.maxHistoricalDeviationBps != 0
                && block.timestamp <= lastAcceptedAt[assetId] + c.historicalDeviationWindow
        ) {
            uint256 diff = mid > old ? mid - old : old - mid;
            if (MathX.mulDiv(diff, 10_000, old) > c.maxHistoricalDeviationBps) {
                revert HistoricalDeviation(assetId, old, mid);
            }
        }
        lastAcceptedMid[assetId] = mid;
        lastAcceptedAt[assetId] = block.timestamp;
        emit PriceAccepted(assetId, data.minPrice, data.maxPrice, data.updatedAt);
    }

    function _read(bytes32 assetId, uint256 maxAge) private view returns (PriceData memory) {
        AssetConfig memory c = configs[assetId];
        if (!c.enabled) revert AssetDisabled(assetId);
        (bool pOk, PriceData memory p) = _tryRead(c.primary, maxAge);
        if (c.mode == Mode.PrimaryOnly) {
            if (!pOk) revert NoValidPrice(assetId);
            return p;
        }
        (bool sOk, PriceData memory s) = _tryRead(c.secondary, maxAge);
        if ((c.mode == Mode.RequireBoth && (!pOk || !sOk)) || (!pOk && !sOk)) {
            revert NoValidPrice(assetId);
        }
        if (!pOk) return s;
        if (!sOk) return p;
        uint256 pm = (p.minPrice + p.maxPrice) / 2;
        uint256 sm = (s.minPrice + s.maxPrice) / 2;
        uint256 diff = pm > sm ? pm - sm : sm - pm;
        if (MathX.mulDiv(diff, 10_000, pm) > c.maxDeviationBps) {
            revert PriceDeviation(assetId, pm, sm);
        }
        p.updatedAt = p.updatedAt < s.updatedAt ? p.updatedAt : s.updatedAt;
        p.marketOpen = p.marketOpen && s.marketOpen;
        return p;
    }

    function _tryRead(address adapter, uint256 maxAge)
        private
        view
        returns (bool ok, PriceData memory data)
    {
        try IPriceAdapter(adapter).getPrice(maxAge) returns (PriceData memory d) {
            if (
                d.minPrice != 0 && d.minPrice <= d.maxPrice
                    && d.maxPrice <= uint256(type(int256).max) && d.updatedAt != 0
                    && d.updatedAt <= block.timestamp && block.timestamp - d.updatedAt <= maxAge
            ) return (true, d);
        } catch { }
        return (false, data);
    }
}
