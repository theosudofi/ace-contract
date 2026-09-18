// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPriceAdapter } from "../interfaces/IPriceAdapter.sol";

struct StorkTemporalNumericValue {
    uint64 timestampNs;
    int192 quantizedValue;
}

interface IStork {
    function getTemporalNumericValueV1(bytes32 id)
        external
        view
        returns (StorkTemporalNumericValue memory value);
}

/// @notice Adapter for Stork's 1e18-quantized EVM price interface.
contract StorkAdapter is IPriceAdapter {
    error InvalidConfig();
    error InvalidPrice();
    error StalePrice();

    IStork public immutable stork;
    bytes32 public immutable feedId;

    constructor(address stork_, bytes32 feedId_) {
        if (stork_ == address(0) || stork_.code.length == 0 || feedId_ == bytes32(0)) {
            revert InvalidConfig();
        }
        stork = IStork(stork_);
        feedId = feedId_;
    }

    function getPrice(uint256 maxAge) external view returns (uint256 priceWad, uint256 updatedAt) {
        StorkTemporalNumericValue memory value = stork.getTemporalNumericValueV1(feedId);
        if (value.quantizedValue <= 0) revert InvalidPrice();
        updatedAt = value.timestampNs / 1e9;
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert StalePrice();
        }
        return (uint192(value.quantizedValue), updatedAt);
    }
}
