// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TestBase } from "./TestBase.sol";
import { AcePerp } from "../src/AcePerp.sol";
import { PriceImpactModel } from "../src/libraries/PriceImpactModel.sol";
import { OracleRouter } from "../src/oracles/OracleRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPriceAdapter } from "./mocks/MockPriceAdapter.sol";

contract AcePerpTest is TestBase {
    address internal constant LP = address(0x1001);
    address internal constant TRADER = address(0x1002);
    address internal constant LIQUIDATOR = address(0x1003);
    bytes32 internal constant USDC = bytes32("USDC");
    bytes32 internal constant ETH = bytes32("ETH");

    MockERC20 internal token;
    MockPriceAdapter internal usdcOracle;
    MockPriceAdapter internal ethOracle;
    OracleRouter internal router;
    AcePerp internal perp;
    uint32 internal marketId;

    function setUp() external {
        vm.warp(1_000_000);
        token = new MockERC20("USD Coin", "USDC", 6);
        usdcOracle = new MockPriceAdapter(1e18, block.timestamp);
        ethOracle = new MockPriceAdapter(2_000e18, block.timestamp);
        router = new OracleRouter(address(this));
        _setOracle(USDC, address(usdcOracle));
        _setOracle(ETH, address(ethOracle));
        perp = new AcePerp(address(this), address(this), address(token), USDC, address(router));

        AcePerp.MarketConfig memory marketConfig = AcePerp.MarketConfig({
            maxOiUsd: uint128(10_000_000e18),
            minPositionSizeUsd: uint128(100e18),
            maxLeverageWad: uint128(20e18),
            maxPriceAge: 60,
            maintenanceMarginWad: uint64(0.05e18),
            tradeFeeWad: uint64(0.001e18),
            liquidationFeeWad: uint64(0.005e18),
            fundingFactorPerSecondWad: uint64(0.00000001e18)
        });
        PriceImpactModel.Config memory impactConfig = PriceImpactModel.Config({
            enabled: true,
            exponent: 2,
            baseSpreadWad: uint64(0.001e18),
            impactFactorWad: uint64(0.01e18),
            maxAdverseImpactWad: uint64(0.05e18),
            maxRebateWad: uint64(0.02e18)
        });
        marketId = perp.createMarket(ETH, marketConfig, impactConfig);

        token.mint(LP, 1_000_000e6);
        token.mint(TRADER, 100_000e6);
        vm.startPrank(LP);
        token.approve(address(perp), type(uint256).max);
        perp.depositLiquidity(500_000e6);
        vm.stopPrank();
        vm.prank(TRADER);
        token.approve(address(perp), type(uint256).max);
    }

    function testOpenAndCloseProfitableLong() external {
        vm.prank(TRADER);
        uint256 positionId = perp.openPosition(marketId, 2_000e6, 10_000e18, true, 2_100e18);
        (address owner,,,, uint256 sizeUsd,,) = perp.positions(positionId);
        assertTrue(owner == TRADER);
        assertEq(sizeUsd, 10_000e18);

        ethOracle.setPrice(2_200e18, block.timestamp);
        uint256 balanceBefore = token.balanceOf(TRADER);
        vm.prank(TRADER);
        uint256 payout = perp.decreasePosition(positionId, 10_000e18, 2_000e18);
        assertTrue(payout > 2_000e6);
        assertEq(token.balanceOf(TRADER), balanceBefore + payout);
    }

    function testPauseBlocksOpeningButNotClosing() external {
        vm.prank(TRADER);
        uint256 positionId = perp.openPosition(marketId, 2_000e6, 10_000e18, true, 2_100e18);
        perp.setPaused(true);
        vm.prank(TRADER);
        vm.expectRevert(AcePerp.ProtocolPaused.selector);
        perp.openPosition(marketId, 2_000e6, 10_000e18, true, 2_100e18);

        vm.prank(TRADER);
        perp.decreasePosition(positionId, 10_000e18, 1_900e18);
    }

    function testFundingChargesCrowdedLongs() external {
        vm.prank(TRADER);
        uint256 positionId = perp.openPosition(marketId, 2_000e6, 10_000e18, true, 2_100e18);
        vm.warp(block.timestamp + 1 days);
        ethOracle.setPrice(2_000e18, block.timestamp);
        usdcOracle.setPrice(1e18, block.timestamp);
        (int256 equity,) = perp.positionEquityUsd(positionId);
        assertTrue(equity < int256(1_990e18)); // net collateral minus positive long funding
    }

    function testLiquidatesUnderwaterPosition() external {
        vm.prank(TRADER);
        uint256 positionId = perp.openPosition(marketId, 1_000e6, 10_000e18, true, 2_100e18);
        ethOracle.setPrice(1_700e18, block.timestamp);
        uint256 liquidatorBefore = token.balanceOf(LIQUIDATOR);
        vm.prank(LIQUIDATOR);
        uint256 reward = perp.liquidate(positionId);
        assertEq(token.balanceOf(LIQUIDATOR), liquidatorBefore + reward);
        (address owner,,,,,,) = perp.positions(positionId);
        assertTrue(owner == address(0));
    }

    function testCannotWithdrawLiquidityBelowReserve() external {
        vm.prank(TRADER);
        perp.openPosition(marketId, 2_000e6, 10_000e18, true, 2_100e18);
        vm.prank(LP);
        vm.expectRevert(AcePerp.ReserveRequirement.selector);
        perp.withdrawLiquidity(500_000e6, 0);
    }

    function testOpeningRequiresPoolBacking() external {
        vm.prank(LP);
        perp.withdrawLiquidity(500_000e6, 0);
        vm.prank(TRADER);
        vm.expectRevert(AcePerp.ReserveRequirement.selector);
        perp.openPosition(marketId, 2_000e6, 10_000e18, true, 2_100e18);
    }

    function testTokenAccountingMatchesPoolPlusPositionMargin() external {
        vm.prank(TRADER);
        uint256 positionId = perp.openPosition(marketId, 2_000e6, 10_000e18, true, 2_100e18);
        (,,, uint256 margin,,,) = perp.positions(positionId);
        assertEq(token.balanceOf(address(perp)), perp.poolLiquidity() + margin);

        vm.prank(TRADER);
        perp.decreasePosition(positionId, 10_000e18, 1_900e18);
        assertEq(token.balanceOf(address(perp)), perp.poolLiquidity());
    }

    function _setOracle(bytes32 assetId, address adapter) private {
        router.setAssetConfig(
            assetId,
            OracleRouter.AssetConfig({
                primary: adapter,
                secondary: address(0),
                maxDeviationBps: 0,
                mode: OracleRouter.Mode.PrimaryOnly,
                enabled: true
            })
        );
    }
}
