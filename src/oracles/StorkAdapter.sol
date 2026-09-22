// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IUpdatablePriceAdapter, PriceData } from "../interfaces/IPriceAdapter.sol";
import { OracleChecks } from "./OracleChecks.sol";

struct StorkTemporalNumericValue {
    uint64 timestampNs;
    int192 quantizedValue;
}

struct StorkTemporalNumericValueInput {
    StorkTemporalNumericValue temporalNumericValue;
    bytes32 id;
    bytes32 publisherMerkleRoot;
    bytes32 valueComputeAlgHash;
    bytes32 r;
    bytes32 s;
    uint8 v;
}

interface IStork {
    function getTemporalNumericValueV1(bytes32 id)
        external
        view
        returns (StorkTemporalNumericValue memory);
    function getUpdateFeeV1(StorkTemporalNumericValueInput[] calldata data)
        external
        view
        returns (uint256);
    function updateTemporalNumericValuesV1(StorkTemporalNumericValueInput[] calldata data)
        external
        payable;
}

contract StorkAdapter is IUpdatablePriceAdapter {
    error InvalidConfig();
    error InvalidPrice();
    error StalePrice();
    error InvalidFee();
    IStork public immutable stork;
    bytes32 public immutable feedId;
    address public immutable sequencerFeed;
    uint32 public immutable sequencerGracePeriod;
    address public immutable marketStatusFeed;
    bool public immutable alwaysOpen;

    constructor(
        address stork_,
        bytes32 id_,
        address sequencer_,
        uint32 grace_,
        address status_,
        bool alwaysOpen_
    ) {
        if (stork_ == address(0) || stork_.code.length == 0 || id_ == 0) {
            revert InvalidConfig();
        }
        stork = IStork(stork_);
        feedId = id_;
        sequencerFeed = sequencer_;
        sequencerGracePeriod = grace_;
        marketStatusFeed = status_;
        alwaysOpen = alwaysOpen_;
    }

    function update(bytes calldata raw) external payable {
        StorkTemporalNumericValueInput[] memory data =
            abi.decode(raw, (StorkTemporalNumericValueInput[]));
        uint256 fee = stork.getUpdateFeeV1(data);
        if (msg.value != fee) revert InvalidFee();
        stork.updateTemporalNumericValuesV1{ value: fee }(data);
    }

    function getPrice(uint256 maxAge) external view returns (PriceData memory data) {
        OracleChecks.validateSequencer(sequencerFeed, sequencerGracePeriod);
        StorkTemporalNumericValue memory v = stork.getTemporalNumericValueV1(feedId);
        if (v.quantizedValue <= 0) revert InvalidPrice();
        uint256 timestamp = v.timestampNs / 1e9;
        if (timestamp == 0 || timestamp > block.timestamp || block.timestamp - timestamp > maxAge) {
            revert StalePrice();
        }
        uint256 price = uint192(v.quantizedValue);
        data = PriceData(
            price, price, timestamp, OracleChecks.marketOpen(marketStatusFeed, alwaysOpen)
        );
    }
}
