// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPriceAdapter, PriceData } from "../interfaces/IPriceAdapter.sol";
import { IAggregatorV3Like, OracleChecks } from "./OracleChecks.sol";

interface IChainlinkAggregatorV3 is IAggregatorV3Like { }

/// @notice Chainlink Data Feed adapter with L2 sequencer and RWA market-status checks.
contract ChainlinkAdapter is IPriceAdapter {
    error InvalidFeed();
    error InvalidPrice();
    error StalePrice();
    IAggregatorV3Like public immutable feed;
    uint8 public immutable feedDecimals;
    address public immutable sequencerFeed;
    uint32 public immutable sequencerGracePeriod;
    address public immutable marketStatusFeed;
    bool public immutable alwaysOpen;

    constructor(
        address feed_,
        address sequencerFeed_,
        uint32 grace_,
        address status_,
        bool alwaysOpen_
    ) {
        if (feed_ == address(0) || feed_.code.length == 0) revert InvalidFeed();
        feed = IAggregatorV3Like(feed_);
        uint8 decimals_ = feed.decimals();
        if (decimals_ > 18) revert InvalidFeed();
        feedDecimals = decimals_;
        sequencerFeed = sequencerFeed_;
        sequencerGracePeriod = grace_;
        marketStatusFeed = status_;
        alwaysOpen = alwaysOpen_;
    }

    function getPrice(uint256 maxAge) external view returns (PriceData memory data) {
        OracleChecks.validateSequencer(sequencerFeed, sequencerGracePeriod);
        (uint80 roundId, int256 answer,, uint256 timestamp, uint80 answeredInRound) =
            feed.latestRoundData();
        if (answer <= 0 || timestamp == 0 || answeredInRound < roundId) revert InvalidPrice();
        if (timestamp > block.timestamp || block.timestamp - timestamp > maxAge) {
            revert StalePrice();
        }
        uint256 price = uint256(answer) * 10 ** (18 - feedDecimals);
        data = PriceData(
            price, price, timestamp, OracleChecks.marketOpen(marketStatusFeed, alwaysOpen)
        );
    }
}
