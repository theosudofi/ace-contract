// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IAggregatorV3Like {
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

library OracleChecks {
    error SequencerDown();
    error SequencerGracePeriod();
    error MarketClosed();

    function validateSequencer(address sequencerFeed, uint256 gracePeriod) internal view {
        if (sequencerFeed == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = IAggregatorV3Like(sequencerFeed).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0 || block.timestamp <= startedAt + gracePeriod) {
            revert SequencerGracePeriod();
        }
    }

    function marketOpen(address statusFeed, bool alwaysOpen) internal view returns (bool) {
        if (alwaysOpen) return true;
        if (statusFeed == address(0)) return false;
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3Like(statusFeed).latestRoundData();
        return answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp;
    }
}
