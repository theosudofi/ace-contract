// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { MarketPoolToken } from "./MarketPoolToken.sol";

contract MarketPoolFactory {
    function create(address controller) external returns (address) {
        return address(new MarketPoolToken("Ace LP", "aceLP", controller));
    }
}
