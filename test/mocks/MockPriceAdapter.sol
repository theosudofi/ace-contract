// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPriceAdapter, PriceData } from "../../src/interfaces/IPriceAdapter.sol";

contract MockPriceAdapter is IPriceAdapter {
    uint256 public price;
    uint256 public timestamp;
    bool public shouldRevert;
    uint256 public minPrice;
    uint256 public maxPrice;
    bool public marketOpen = true;

    constructor(uint256 price_, uint256 timestamp_) {
        price = price_;
        minPrice = price_;
        maxPrice = price_;
        timestamp = timestamp_;
    }

    function setPrice(uint256 price_, uint256 timestamp_) external {
        price = price_;
        minPrice = price_;
        maxPrice = price_;
        timestamp = timestamp_;
    }

    function setPriceData(uint256 min_, uint256 max_, uint256 timestamp_, bool open_) external {
        minPrice = min_;
        maxPrice = max_;
        price = (min_ + max_) / 2;
        timestamp = timestamp_;
        marketOpen = open_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function getPrice(uint256) external view returns (PriceData memory) {
        require(!shouldRevert, "mock revert");
        return PriceData(minPrice, maxPrice, timestamp, marketOpen);
    }
}
