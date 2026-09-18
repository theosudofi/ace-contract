// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { AcePerp } from "../src/AcePerp.sol";
import { OracleRouter } from "../src/oracles/OracleRouter.sol";
import { ChainlinkAdapter } from "../src/oracles/ChainlinkAdapter.sol";

interface VmScript {
    function envUint(string calldata name) external view returns (uint256);
    function envAddress(string calldata name) external view returns (address);
    function envBytes32(string calldata name) external view returns (bytes32);
    function addr(uint256 privateKey) external view returns (address);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

/// @notice Deploys the core and two Chainlink feed adapters. Markets are configured separately.
contract Deploy {
    VmScript private constant vm =
        VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run()
        external
        returns (
            OracleRouter router,
            AcePerp perp,
            ChainlinkAdapter collateralAdapter,
            ChainlinkAdapter indexAdapter
        )
    {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address guardian = vm.envAddress("GUARDIAN");
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN");
        bytes32 collateralAssetId = vm.envBytes32("COLLATERAL_ASSET_ID");
        bytes32 indexAssetId = vm.envBytes32("INDEX_ASSET_ID");

        vm.startBroadcast(privateKey);
        router = new OracleRouter(deployer);
        collateralAdapter = new ChainlinkAdapter(vm.envAddress("COLLATERAL_CHAINLINK_FEED"));
        indexAdapter = new ChainlinkAdapter(vm.envAddress("INDEX_CHAINLINK_FEED"));
        router.setAssetConfig(
            collateralAssetId,
            OracleRouter.AssetConfig({
                primary: address(collateralAdapter),
                secondary: address(0),
                maxDeviationBps: 0,
                mode: OracleRouter.Mode.PrimaryOnly,
                enabled: true
            })
        );
        router.setAssetConfig(
            indexAssetId,
            OracleRouter.AssetConfig({
                primary: address(indexAdapter),
                secondary: address(0),
                maxDeviationBps: 0,
                mode: OracleRouter.Mode.PrimaryOnly,
                enabled: true
            })
        );
        perp = new AcePerp(deployer, guardian, collateralToken, collateralAssetId, address(router));
        vm.stopBroadcast();
    }
}
