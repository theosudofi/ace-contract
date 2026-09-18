// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPriceAdapter } from "../../src/interfaces/IPriceAdapter.sol";

contract MockPriceAdapter is IPriceAdapter {
    uint256 public price;
    uint256 public timestamp;
    bool public shouldRevert;

    constructor(uint256 price_, uint256 timestamp_) {
        price = price_;
        timestamp = timestamp_;
    }

    function setPrice(uint256 price_, uint256 timestamp_) external {
        price = price_;
        timestamp = timestamp_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function getPrice(uint256) external view returns (uint256, uint256) {
        require(!shouldRevert, "mock revert");
        return (price, timestamp);
    }
}

