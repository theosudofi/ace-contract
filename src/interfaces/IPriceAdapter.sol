// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Common boundary for push and pull oracle implementations.
/// @dev Prices are unsigned USD values with 18 decimals. Adapters must reject invalid prices.
interface IPriceAdapter {
    function getPrice(uint256 maxAge) external view returns (uint256 priceWad, uint256 updatedAt);
}

