// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { AceOrderManager } from "../src/AceOrderManager.sol";
import { AcePerp } from "../src/AcePerp.sol";
import { PoolLogic } from "../src/PoolLogic.sol";
import { TradeLogic } from "../src/TradeLogic.sol";
import { OracleRouter } from "../src/oracles/OracleRouter.sol";

interface VmScript {
    function envUint(string calldata name) external view returns (uint256);
    function envAddress(string calldata name) external view returns (address);
    function addr(uint256 privateKey) external view returns (address);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

/// @notice Deploys the oracle router, the core, and the order manager. Pools and markets come later.
contract Deploy {
    VmScript private constant vm =
        VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (OracleRouter router, AcePerp perp, AceOrderManager orders) {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address guardian = vm.envAddress("GUARDIAN");

        vm.startBroadcast(privateKey);
        router = new OracleRouter(deployer);
        PoolLogic poolLogic = new PoolLogic();
        TradeLogic tradeLogic = new TradeLogic();
        perp = new AcePerp(
            deployer, guardian, address(router), address(poolLogic), address(tradeLogic)
        );
        orders = new AceOrderManager(deployer, address(perp), 0);
        perp.setOrderManager(address(orders));
        vm.stopBroadcast();
    }
}
