// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TestBase } from "./TestBase.sol";
import { PriceData } from "../src/interfaces/IPriceAdapter.sol";
import { ChainlinkAdapter, IChainlinkAggregatorV3 } from "../src/oracles/ChainlinkAdapter.sol";
import { PythAdapter, PythPrice, IPyth } from "../src/oracles/PythAdapter.sol";
import {
    StorkAdapter,
    StorkTemporalNumericValue,
    StorkTemporalNumericValueInput,
    IStork
} from "../src/oracles/StorkAdapter.sol";
import {
    ChainlinkDataStreamAdapter,
    IChainlinkDataStreamVerifier
} from "../src/oracles/ChainlinkDataStreamAdapter.sol";

contract MockChainlink is IChainlinkAggregatorV3 {
    uint8 public decimals = 8;
    int256 public answer = 2_000e8;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 time_) external {
        answer = answer_;
        updatedAt = time_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (2, answer, updatedAt, updatedAt, 2);
    }
}

contract MockPyth is IPyth {
    PythPrice value;
    uint256 public updates;

    function set(PythPrice memory v) external {
        value = v;
    }

    function getPriceNoOlderThan(bytes32, uint256) external view returns (PythPrice memory) {
        return value;
    }

    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 1;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value == 1);
        updates++;
    }
}

contract MockStork is IStork {
    StorkTemporalNumericValue value;
    uint256 public updates;

    function set(StorkTemporalNumericValue memory v) external {
        value = v;
    }

    function getTemporalNumericValueV1(bytes32)
        external
        view
        returns (StorkTemporalNumericValue memory)
    {
        return value;
    }

    function getUpdateFeeV1(StorkTemporalNumericValueInput[] calldata)
        external
        pure
        returns (uint256)
    {
        return 1;
    }

    function updateTemporalNumericValuesV1(StorkTemporalNumericValueInput[] calldata)
        external
        payable
    {
        require(msg.value == 1);
        updates++;
    }
}

contract MockVerifier is IChainlinkDataStreamVerifier {
    bytes public report;

    function set(bytes calldata value) external {
        report = value;
    }

    function verify(bytes calldata, bytes calldata) external payable returns (bytes memory) {
        return report;
    }
}

contract OracleAdaptersTest is TestBase {
    bytes32 constant ID = keccak256("ETHUSD");

    function setUp() external {
        vm.warp(1_000_000);
    }

    function testChainlinkNormalizes() external {
        ChainlinkAdapter a =
            new ChainlinkAdapter(address(new MockChainlink()), address(0), 0, address(0), true);
        PriceData memory p = a.getPrice(60);
        assertEq(p.minPrice, 2_000e18);
        assertTrue(p.marketOpen);
    }

    function testPythBidAskAndSameTransactionUpdate() external {
        MockPyth m = new MockPyth();
        m.set(PythPrice(200_000_000_000, 100_000_000, -8, block.timestamp));
        PythAdapter a = new PythAdapter(address(m), ID, 100, address(0), 0, address(0), true);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = hex"01";
        a.update{ value: 1 }(abi.encode(payloads));
        PriceData memory p = a.getPrice(60);
        assertEq(p.minPrice, 1_999e18);
        assertEq(p.maxPrice, 2_001e18);
        assertEq(m.updates(), 1);
    }

    function testStorkSameTransactionUpdate() external {
        MockStork m = new MockStork();
        m.set(StorkTemporalNumericValue(uint64(block.timestamp * 1e9), int192(2_000e18)));
        StorkAdapter a = new StorkAdapter(address(m), ID, address(0), 0, address(0), true);
        StorkTemporalNumericValueInput[] memory values = new StorkTemporalNumericValueInput[](0);
        a.update{ value: 1 }(abi.encode(values));
        PriceData memory p = a.getPrice(60);
        assertEq(p.minPrice, 2_000e18);
        assertEq(m.updates(), 1);
    }

    function testDataStreamVerificationPreservesBidAsk() external {
        MockVerifier v = new MockVerifier();
        ChainlinkDataStreamAdapter.Report memory r = ChainlinkDataStreamAdapter.Report(
            ID,
            uint32(block.timestamp),
            uint32(block.timestamp),
            0,
            0,
            uint32(block.timestamp + 60),
            int192(2_000e8),
            int192(1_999e8),
            int192(2_001e8)
        );
        v.set(abi.encode(r));
        ChainlinkDataStreamAdapter a =
            new ChainlinkDataStreamAdapter(address(v), ID, 8, address(0), 0, address(0), true);
        a.update(hex"1234");
        PriceData memory p = a.getPrice(60);
        assertEq(p.minPrice, 1_999e18);
        assertEq(p.maxPrice, 2_001e18);
    }

    function testSequencerValidation() external {
        MockChainlink feed = new MockChainlink();
        MockChainlink sequencer = new MockChainlink();
        sequencer.set(1, block.timestamp - 1 hours);
        ChainlinkAdapter a =
            new ChainlinkAdapter(address(feed), address(sequencer), 60, address(0), true);
        vm.expectRevert();
        a.getPrice(60);
    }
}
