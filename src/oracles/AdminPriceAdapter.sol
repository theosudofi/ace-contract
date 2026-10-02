// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable2Step } from "../access/Ownable2Step.sol";
import { IPriceAdapter, PriceData } from "../interfaces/IPriceAdapter.sol";

/// @notice Owner-published USD price. Used when a Chainlink feed is not deployed on the network.
contract AdminPriceAdapter is Ownable2Step, IPriceAdapter {
    error InvalidPrice();
    error StalePrice();

    uint256 public minPrice;
    uint256 public maxPrice;
    uint256 public updatedAt;
    bool public marketOpen;

    constructor(address initialOwner, uint256 price) Ownable2Step(initialOwner) {
        _set(price, price, true);
    }

    function setPrice(uint256 price, bool open) external onlyOwner {
        _set(price, price, open);
    }

    function setBidAsk(uint256 min_, uint256 max_, bool open) external onlyOwner {
        _set(min_, max_, open);
    }

    function getPrice(uint256 maxAge) external view returns (PriceData memory) {
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert StalePrice();
        }
        return PriceData(minPrice, maxPrice, updatedAt, marketOpen);
    }

    function _set(uint256 min_, uint256 max_, bool open) private {
        if (min_ == 0 || max_ < min_) revert InvalidPrice();
        minPrice = min_;
        maxPrice = max_;
        updatedAt = block.timestamp;
        marketOpen = open;
    }
}
