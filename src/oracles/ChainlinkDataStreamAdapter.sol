// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IUpdatablePriceAdapter, PriceData } from "../interfaces/IPriceAdapter.sol";
import { OracleChecks } from "./OracleChecks.sol";

interface IChainlinkDataStreamVerifier {
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory);
}

/// @notice Verifies and stores signed Chainlink Data Streams bid/ask reports.
contract ChainlinkDataStreamAdapter is IUpdatablePriceAdapter {
    struct Report {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 price;
        int192 bid;
        int192 ask;
    }
    error InvalidConfig();
    error InvalidReport();
    error StalePrice();
    IChainlinkDataStreamVerifier public immutable verifier;
    bytes32 public immutable feedId;
    uint8 public immutable reportDecimals;
    address public immutable sequencerFeed;
    uint32 public immutable sequencerGracePeriod;
    address public immutable marketStatusFeed;
    bool public immutable alwaysOpen;
    PriceData private latest;

    constructor(
        address verifier_,
        bytes32 feedId_,
        uint8 decimals_,
        address sequencer_,
        uint32 grace_,
        address status_,
        bool alwaysOpen_
    ) {
        if (verifier_ == address(0) || verifier_.code.length == 0 || feedId_ == 0 || decimals_ > 18)
        {
            revert InvalidConfig();
        }
        verifier = IChainlinkDataStreamVerifier(verifier_);
        feedId = feedId_;
        reportDecimals = decimals_;
        sequencerFeed = sequencer_;
        sequencerGracePeriod = grace_;
        marketStatusFeed = status_;
        alwaysOpen = alwaysOpen_;
    }

    function update(bytes calldata payload) external payable {
        bytes memory verified = verifier.verify{ value: msg.value }(payload, bytes(""));
        Report memory r = abi.decode(verified, (Report));
        if (
            r.feedId != feedId || r.price <= 0 || r.bid <= 0 || r.ask <= 0 || r.bid > r.ask
                || r.observationsTimestamp < r.validFromTimestamp
                || r.observationsTimestamp > block.timestamp || r.expiresAt < block.timestamp
        ) revert InvalidReport();
        uint256 scale = 10 ** (18 - reportDecimals);
        latest = PriceData(
            uint192(r.bid) * scale, uint192(r.ask) * scale, r.observationsTimestamp, true
        );
    }

    function getPrice(uint256 maxAge) external view returns (PriceData memory data) {
        OracleChecks.validateSequencer(sequencerFeed, sequencerGracePeriod);
        data = latest;
        if (
            data.updatedAt == 0 || data.updatedAt > block.timestamp
                || block.timestamp - data.updatedAt > maxAge
        ) revert StalePrice();
        data.marketOpen = OracleChecks.marketOpen(marketStatusFeed, alwaysOpen);
    }
}
