// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { MarketPoolToken } from "./MarketPoolToken.sol";

contract MarketPoolFactory {
    function create(address asset, address controller, bool isLong) external returns (address) {
        return address(
            new MarketPoolToken(
                isLong ? "Ace Long Market Pool" : "Ace Short Market Pool",
                isLong ? "aceLP-L" : "aceLP-S",
                asset,
                controller
            )
        );
    }
}
