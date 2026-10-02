// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { PriceData } from "./interfaces/IPriceAdapter.sol";
import { MathX } from "./libraries/MathX.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { MarketPoolToken } from "./market/MarketPoolToken.sol";
import { PerpStore } from "./PerpStore.sol";

/// @notice Position actions. Executed by delegatecall from AcePerp.
contract TradeLogic is PerpStore {
    using SafeTransferLib for address;
    constructor() PerpStore(address(1)) { }

    function increasePosition(
        uint256 id,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 acceptable
    ) external nonReentrant {
        _checkFn(FN_INCREASE);
        Position storage p = _owned(id, msg.sender);
        _increase(p, id, msg.sender, collateralDelta, sizeDelta, acceptable, 0);
    }

    function addCollateral(uint256 id, uint256 amount) external nonReentrant {
        Position storage p = _owned(id, msg.sender);
        if (amount == 0) revert InvalidAmount();
        Market storage m = markets[p.marketId];
        p.collateralToken.safeTransferFrom(msg.sender, address(_vault(m)), amount);
        p.collateralAmount += amount;
        emit CollateralChanged(id, int256(amount));
    }

    function withdrawCollateral(uint256 id, uint256 amount) external nonReentrant {
        Position storage p = _owned(id, msg.sender);
        if (amount == 0 || amount >= p.collateralAmount) revert InvalidAmount();
        Market storage m = markets[p.marketId];
        _accrueVault(tokenVaults[m.poolId][p.collateralToken]);
        _accrueFunding(m);
        p.collateralAmount -= amount;
        _requireHealthy(p, m);
        _vault(m).transferToken(p.collateralToken, msg.sender, amount);
        emit CollateralChanged(id, -int256(amount));
    }

    function executeOrderIncrease(
        address account,
        uint32 marketId,
        uint256 positionId,
        address collateralToken,
        uint256 collateral,
        uint256 size,
        bool isLong,
        uint256 acceptable,
        uint256 submittedAt,
        address keeper
    ) external nonReentrant returns (uint256 id) {
        _checkFn(FN_OPEN);
        if (msg.sender != orderManager) revert UnauthorizedCaller();
        if (positionId == 0) {
            id = _open(
                account,
                msg.sender,
                marketId,
                collateralToken,
                collateral,
                size,
                isLong,
                acceptable,
                submittedAt
            );
        } else {
            Position storage p = _owned(positionId, account);
            if (collateral != 0 && collateralToken != p.collateralToken) {
                revert UnsupportedCollateral();
            }
            _increase(p, positionId, msg.sender, collateral, size, acceptable, submittedAt);
            id = positionId;
        }
        keeper;
    }

    function executeOrderDecrease(
        address account,
        uint256 positionId,
        uint256 size,
        uint256 acceptable,
        uint256 submittedAt,
        address keeper
    ) external nonReentrant returns (uint256) {
        _checkFn(FN_DECREASE);
        if (msg.sender != orderManager) revert UnauthorizedCaller();
        Position storage p = _owned(positionId, account);
        return _decrease(p, positionId, account, size, acceptable, submittedAt, keeper);
    }

    function liquidate(uint256 id) external nonReentrant returns (uint256 reward) {
        _checkFn(FN_LIQUIDATE);
        Position storage p = positions[id];
        if (p.owner == address(0)) revert PositionNotFound();
        Market storage m = markets[p.marketId];
        TokenVault storage vault = tokenVaults[m.poolId][p.collateralToken];
        _accrueVault(vault);
        _accrueFunding(m);
        address token = p.collateralToken;
        PoolAsset storage asset = _asset(m.poolId, token);
        PriceData memory ip =
            oracle.getPriceForAction(m.assetId, m.config.maxLiquidationPriceAge, 0);
        PriceData memory cp =
            oracle.getPriceForAction(asset.assetId, m.config.maxLiquidationPriceAge, 0);
        uint256 mark = p.isLong ? ip.minPrice : ip.maxPrice;
        int256 equity = _equity(p, m, mark, cp.minPrice, asset.scale);
        if (equity > int256(MathX.mulDiv(p.sizeUsd, m.config.maintenanceMarginWad, WAD))) {
            revert PositionHealthy();
        }
        address account = p.owner;
        int256 closedPnl = _pnl(p.sizeTokens, p.sizeUsd, mark, p.isLong);
        _applyReservingCharge(vault, _reservingFeeTokens(p, vault.accReservingRate));
        _book(m, p.isLong)
        .unrealisedFundingUsd -= _fundingPayment(p, _book(m, p.isLong).accFundingRate, p.sizeUsd);
        _book(m, p.isLong).realisedPnlUsd += closedPnl > 0 ? -closedPnl : closedPnl;
        if (p.isLong) m.longOiUsd -= p.sizeUsd;
        else m.shortOiUsd -= p.sizeUsd;
        _subSize(m, p.isLong, p.sizeTokens);
        vault.reserved -= p.reservedAmount;
        vault.liquidity += p.reservedAmount;
        uint256 collateral = p.collateralAmount;
        if (equity < 0) {
            uint256 lossTokens = _toTokenUp(uint256(-equity), cp.minPrice, asset.scale);
            if (lossTokens > collateral) lossTokens = collateral;
            collateral -= lossTokens;
            vault.liquidity += lossTokens;
        }
        uint256 positive = equity > 0 ? uint256(equity) : 0;
        reward = _toToken(
            MathX.min(positive, MathX.mulDiv(p.sizeUsd, m.config.liquidationFeeWad, WAD)),
            cp.maxPrice,
            asset.scale
        );
        if (reward > collateral) reward = collateral;
        uint256 userPayout = collateral - reward;
        MarketPoolToken pool = _vault(m);
        delete positions[id];
        if (reward != 0) pool.transferToken(token, msg.sender, reward);
        if (userPayout != 0) pool.transferToken(token, account, userPayout);
        if (closedPnl < 0) {
            _payLossCut(pool, vault, token, uint256(-closedPnl), cp.maxPrice, asset.scale);
        }
        emit PositionLiquidated(id, msg.sender, reward);
    }

    function positionEquityUsd(uint256 id) external view returns (int256 equity, uint256 mark) {
        Position storage p = positions[id];
        if (p.owner == address(0)) revert PositionNotFound();
        Market storage m = markets[p.marketId];
        PoolAsset storage asset = _asset(m.poolId, p.collateralToken);
        PriceData memory ip = oracle.getPrice(m.assetId, m.config.maxClosePriceAge);
        PriceData memory cp = oracle.getPrice(asset.assetId, m.config.maxClosePriceAge);
        mark = p.isLong ? ip.minPrice : ip.maxPrice;
        equity = _equity(p, m, mark, cp.minPrice, asset.scale);
    }
}
