// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { AcePerp } from "../src/AcePerp.sol";
import { PerpStore } from "../src/PerpStore.sol";
import { PriceImpactModel } from "../src/libraries/PriceImpactModel.sol";
import { AdminPriceAdapter } from "../src/oracles/AdminPriceAdapter.sol";
import { OracleRouter } from "../src/oracles/OracleRouter.sol";

interface VmScript {
    function envUint(string calldata name) external view returns (uint256);
    function addr(uint256 privateKey) external view returns (address);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

/// @notice Creates the AMZN/USDG pool and the AMZN perp on the deployed core.
contract CreateAmznPool {
    VmScript private constant vm =
        VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant USDG = 0x7E955252E15c84f5768B83c41a71F9eba181802F;
    address private constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    OracleRouter private constant ROUTER = OracleRouter(0x2F9df9E6a81FaF900e4318426A9871666331b917);
    AcePerp private constant PERP = AcePerp(0x9E0e47B9C1a8D3528D4EB1a53A944CFbfe1258dc);

    bytes32 private constant AMZN_ID = bytes32("AMZN");
    bytes32 private constant USDG_ID = bytes32("USDG");

    function run()
        external
        returns (
            uint32 poolId,
            uint32 marketId,
            address lpToken,
            AdminPriceAdapter amznPrice,
            AdminPriceAdapter usdgPrice
        )
    {
        uint256 privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        amznPrice = new AdminPriceAdapter(deployer, 248.23 ether);
        usdgPrice = new AdminPriceAdapter(deployer, 1 ether);
        _configure(AMZN_ID, address(amznPrice));
        _configure(USDG_ID, address(usdgPrice));

        PerpStore.CollateralAsset[] memory assets = new PerpStore.CollateralAsset[](2);
        assets[0] = PerpStore.CollateralAsset({ token: AMZN, assetId: AMZN_ID });
        assets[1] = PerpStore.CollateralAsset({ token: USDG, assetId: USDG_ID });
        poolId = PERP.createPool(assets, 7 days);
        marketId = PERP.createMarket(poolId, AMZN_ID, _marketConfig(), _impact());
        (,, lpToken) = PERP.pools(poolId);
        vm.stopBroadcast();
    }

    function _configure(bytes32 assetId, address primary) private {
        ROUTER.setAssetConfig(
            assetId,
            OracleRouter.AssetConfig({
                primary: primary,
                secondary: address(0),
                maxDeviationBps: 0,
                maxHistoricalDeviationBps: 5_000,
                historicalDeviationWindow: 1 hours,
                mode: OracleRouter.Mode.PrimaryOnly,
                enabled: true,
                requireMarketOpen: true
            })
        );
    }

    function _marketConfig() private pure returns (PerpStore.MarketConfig memory) {
        return PerpStore.MarketConfig({
            maxOiUsd: 1_000_000 ether,
            minPositionSizeUsd: 1_000 ether,
            maxLeverageWad: 20 ether,
            maxOpenPriceAge: 7 days,
            maxClosePriceAge: 7 days,
            maxLiquidationPriceAge: 7 days,
            maintenanceMarginWad: 0.05 ether,
            tradeFeeWad: 0.001 ether,
            liquidationFeeWad: 0.01 ether,
            borrowingFactorPerSecondWad: 0,
            reserveFactorWad: 0.1 ether
        });
    }

    function _impact() private pure returns (PriceImpactModel.Config memory) {
        return PriceImpactModel.Config({
            enabled: false,
            exponent: 1,
            baseSpreadWad: 0,
            impactFactorWad: 0,
            maxAdverseImpactWad: 0.1 ether,
            maxRebateWad: 0.05 ether
        });
    }
}
