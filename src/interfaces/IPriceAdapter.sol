// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

struct PriceData {
    uint256 minPrice;
    uint256 maxPrice;
    uint256 updatedAt;
    bool marketOpen;
}

/// @notice Common boundary for push and pull oracle implementations.
/// @dev Prices are unsigned USD values with 18 decimals. Adapters must reject invalid prices.
interface IPriceAdapter {
    function getPrice(uint256 maxAge) external view returns (PriceData memory);
}

interface IUpdatablePriceAdapter is IPriceAdapter {
    function update(bytes calldata updateData) external payable;
}
