// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPriceAdapter } from "../interfaces/IPriceAdapter.sol";

interface IChainlinkAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @notice Adapter for Chainlink Data Feeds. This is the default Robinhood Chain oracle path.
contract ChainlinkAdapter is IPriceAdapter {
    error InvalidFeed();
    error InvalidPrice();
    error StalePrice();

    IChainlinkAggregatorV3 public immutable feed;
    uint8 public immutable feedDecimals;

    constructor(address feed_) {
        if (feed_ == address(0) || feed_.code.length == 0) revert InvalidFeed();
        feed = IChainlinkAggregatorV3(feed_);
        uint8 decimals_ = feed.decimals();
        if (decimals_ > 18) revert InvalidFeed();
        feedDecimals = decimals_;
    }

    function getPrice(uint256 maxAge) external view returns (uint256 priceWad, uint256 updatedAt) {
        (uint80 roundId, int256 answer,, uint256 timestamp, uint80 answeredInRound) =
            feed.latestRoundData();
        if (answer <= 0 || timestamp == 0 || answeredInRound < roundId) revert InvalidPrice();
        if (timestamp > block.timestamp || block.timestamp - timestamp > maxAge) {
            revert StalePrice();
        }
        return (uint256(answer) * (10 ** (18 - feedDecimals)), timestamp);
    }
}

