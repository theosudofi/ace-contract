// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TestBase } from "./TestBase.sol";
import { ChainlinkAdapter, IChainlinkAggregatorV3 } from "../src/oracles/ChainlinkAdapter.sol";
import { PythAdapter, PythPrice, IPyth } from "../src/oracles/PythAdapter.sol";
import { StorkAdapter, StorkTemporalNumericValue, IStork } from "../src/oracles/StorkAdapter.sol";

contract MockChainlink is IChainlinkAggregatorV3 {
    uint8 public immutable decimals = 8;
    int256 public answer = 2_000e8;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (2, answer, updatedAt, updatedAt, 2);
    }
}

contract MockPyth is IPyth {
    PythPrice internal value;

    function set(PythPrice memory value_) external {
        value = value_;
    }

    function getPriceNoOlderThan(bytes32, uint256) external view returns (PythPrice memory) {
        return value;
    }
}

contract MockStork is IStork {
    StorkTemporalNumericValue internal value;

    function set(StorkTemporalNumericValue memory value_) external {
        value = value_;
    }

    function getTemporalNumericValueV1(bytes32)
        external
        view
        returns (StorkTemporalNumericValue memory)
    {
        return value;
    }
}

contract OracleAdaptersTest is TestBase {
    bytes32 internal constant FEED_ID = keccak256("ETHUSD");

    function setUp() external {
        vm.warp(1_000_000);
    }

    function testChainlinkNormalizesEightDecimals() external {
        ChainlinkAdapter adapter = new ChainlinkAdapter(address(new MockChainlink()));
        (uint256 price,) = adapter.getPrice(60);
        assertEq(price, 2_000e18);
    }

    function testPythNormalizesAndChecksConfidence() external {
        MockPyth pyth = new MockPyth();
        pyth.set(
            PythPrice({
                price: 200_000_000_000, conf: 100_000_000, expo: -8, publishTime: block.timestamp
            })
        );
        PythAdapter adapter = new PythAdapter(address(pyth), FEED_ID, 100);
        (uint256 price,) = adapter.getPrice(60);
        assertEq(price, 2_000e18);

        pyth.set(
            PythPrice({
                price: 200_000_000_000, conf: 4_000_000_000, expo: -8, publishTime: block.timestamp
            })
        );
        vm.expectRevert(PythAdapter.ConfidenceTooWide.selector);
        adapter.getPrice(60);
    }

    function testStorkReadsOneEighteenQuantizedPrice() external {
        MockStork stork = new MockStork();
        stork.set(
            StorkTemporalNumericValue({
                timestampNs: uint64(block.timestamp * 1e9), quantizedValue: int192(2_000e18)
            })
        );
        StorkAdapter adapter = new StorkAdapter(address(stork), FEED_ID);
        (uint256 price,) = adapter.getPrice(60);
        assertEq(price, 2_000e18);
    }
}
