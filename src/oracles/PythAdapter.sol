// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IUpdatablePriceAdapter, PriceData } from "../interfaces/IPriceAdapter.sol";
import { MathX } from "../libraries/MathX.sol";
import { OracleChecks } from "./OracleChecks.sol";

struct PythPrice {
    int64 price;
    uint64 conf;
    int32 expo;
    uint256 publishTime;
}

interface IPyth {
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythPrice memory);
    function getUpdateFee(bytes[] calldata data) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata data) external payable;
}

contract PythAdapter is IUpdatablePriceAdapter {
    error InvalidConfig();
    error InvalidPrice();
    error ConfidenceTooWide();
    error InvalidFee();
    IPyth public immutable pyth;
    bytes32 public immutable priceId;
    uint16 public immutable maxConfidenceBps;
    address public immutable sequencerFeed;
    uint32 public immutable sequencerGracePeriod;
    address public immutable marketStatusFeed;
    bool public immutable alwaysOpen;

    constructor(
        address pyth_,
        bytes32 priceId_,
        uint16 confidenceBps_,
        address sequencer_,
        uint32 grace_,
        address status_,
        bool alwaysOpen_
    ) {
        if (
            pyth_ == address(0) || pyth_.code.length == 0 || priceId_ == 0
                || confidenceBps_ > 10_000
        ) revert InvalidConfig();
        pyth = IPyth(pyth_);
        priceId = priceId_;
        maxConfidenceBps = confidenceBps_;
        sequencerFeed = sequencer_;
        sequencerGracePeriod = grace_;
        marketStatusFeed = status_;
        alwaysOpen = alwaysOpen_;
    }

    function update(bytes calldata raw) external payable {
        bytes[] memory data = abi.decode(raw, (bytes[]));
        uint256 fee = pyth.getUpdateFee(data);
        if (msg.value != fee) revert InvalidFee();
        pyth.updatePriceFeeds{ value: fee }(data);
    }

    function getPrice(uint256 maxAge) external view returns (PriceData memory data) {
        OracleChecks.validateSequencer(sequencerFeed, sequencerGracePeriod);
        PythPrice memory v = pyth.getPriceNoOlderThan(priceId, maxAge);
        if (v.price <= 0 || v.publishTime > block.timestamp) revert InvalidPrice();
        if (MathX.mulDiv(v.conf, 10_000, uint64(v.price)) > maxConfidenceBps) {
            revert ConfidenceTooWide();
        }
        uint256 mid = _toWad(uint64(v.price), v.expo);
        uint256 conf = _toWad(v.conf, v.expo);
        if (conf >= mid) revert InvalidPrice();
        data = PriceData(
            mid - conf,
            mid + conf,
            v.publishTime,
            OracleChecks.marketOpen(marketStatusFeed, alwaysOpen)
        );
    }

    function _toWad(uint256 value, int32 exponent) private pure returns (uint256) {
        int256 scale = int256(18) + exponent;
        if (scale >= 0) {
            if (scale > 59) revert InvalidPrice();
            return value * 10 ** uint256(scale);
        }
        if (scale < -77) revert InvalidPrice();
        uint256 result = value / 10 ** uint256(-scale);
        if (result == 0 && value != 0) revert InvalidPrice();
        return result;
    }
}
