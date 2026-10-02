// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { PriceData } from "./interfaces/IPriceAdapter.sol";
import { MathX } from "./libraries/MathX.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { MarketPoolToken } from "./market/MarketPoolToken.sol";
import { PerpStore } from "./PerpStore.sol";

/// @notice LP vault actions. Executed by delegatecall from AcePerp.
contract PoolLogic is PerpStore {
    using SafeTransferLib for address;
    constructor() PerpStore(address(1)) { }

    /// @notice `mode` 0 is off, 1 is open-interest skew, 2 is LP PnL including open mark-to-market.
    /// Rates are per eight hours. Exponent applies to mode 1 and is 1, 2, or 3.
    function setFundingConfig(
        uint32 id,
        uint8 mode,
        uint64 multiplierWad,
        uint64 maxRateWad,
        uint8 exponent
    ) external onlyOwner {
        if (mode > 2 || exponent < 1 || exponent > 3 || maxRateWad > 0.01e18) {
            revert InvalidConfig();
        }
        if (multiplierWad > 0.1e18) revert InvalidConfig();
        Market storage m = _market(id);
        _accrueFunding(m);
        m.fundingMode = mode;
        m.fundingMultiplierWad = multiplierWad;
        m.fundingMaxRateWad = maxRateWad;
        m.fundingExponent = exponent;
        emit FundingConfigUpdated(id, mode, multiplierWad, maxRateWad, exponent);
    }

    function setReservingFee(uint32 poolId, address token, uint64 multiplierWad)
        external
        onlyOwner
    {
        if (multiplierWad > 0.1e18) revert InvalidConfig();
        _liquidityPool(poolId);
        TokenVault storage vault = _tokenVault(poolId, token);
        _accrueVault(vault);
        vault.reservingMultiplierWad = multiplierWad;
        emit ReservingFeeUpdated(poolId, token, multiplierWad);
    }

    /// @notice `maxLiquidity` of zero means the vault has no ceiling.
    function setVaultBounds(
        uint32 poolId,
        address token,
        uint256 minLiquidity,
        uint256 maxLiquidity
    ) external onlyOwner {
        _liquidityPool(poolId);
        TokenVault storage vault = _tokenVault(poolId, token);
        if (maxLiquidity != 0 && minLiquidity > maxLiquidity) revert InvalidConfig();
        vault.minLiquidity = minLiquidity;
        vault.maxLiquidity = maxLiquidity;
        emit VaultBoundsUpdated(poolId, token, minLiquidity, maxLiquidity);
    }

    function depositLiquidity(uint32 poolId, address token, uint256 amount, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _checkFn(FN_DEPOSIT);
        if (amount == 0) revert InvalidAmount();
        Pool storage pool = _liquidityPool(poolId);
        _accruePool(poolId);
        MarketPoolToken shareToken = MarketPoolToken(pool.vault);
        PoolAsset storage asset = _asset(poolId, token);
        TokenVault storage vault = tokenVaults[poolId][token];
        if (vault.maxLiquidity != 0 && vault.liquidity + amount > vault.maxLiquidity) {
            revert InsufficientLiquidity();
        }
        uint256 supply = shareToken.totalSupply();
        uint256 nav = poolNavUsd(poolId);
        PriceData memory cp = oracle.getPriceForAction(asset.assetId, pool.maxPriceAge, 0);
        uint256 usd = _toUsd(amount, cp.minPrice, asset.scale);
        uint256 vaultUsd = _vaultValue(poolId, token, cp.minPrice);
        uint256 totalUsd = _poolVaultsUsd(poolId);
        uint256 feeUsd = _rebaseFeeUsd(true, vaultUsd, totalUsd, usd, asset.targetWeightBps);
        if (feeUsd >= usd) revert SlippageExceeded();
        uint256 netUsd = usd - feeUsd;
        shares = supply == 0 ? netUsd : MathX.mulDiv(netUsd, supply, nav);
        if (shares == 0 || shares < minShares) revert SlippageExceeded();
        token.safeTransferFrom(msg.sender, address(shareToken), amount);
        vault.liquidity += amount;
        shareToken.mint(msg.sender, shares);
        emit LiquidityDeposited(msg.sender, poolId, token, amount, shares);
    }

    function withdrawLiquidity(uint32 poolId, address token, uint256 shares, uint256 minAmount)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _checkFn(FN_WITHDRAW);
        if (shares == 0) revert InvalidAmount();
        Pool storage pool = _liquidityPool(poolId);
        _accruePool(poolId);
        MarketPoolToken shareToken = MarketPoolToken(pool.vault);
        PoolAsset storage asset = _asset(poolId, token);
        TokenVault storage vault = tokenVaults[poolId][token];
        uint256 supply = shareToken.totalSupply();
        if (shares > shareToken.balanceOf(msg.sender)) revert InvalidAmount();
        uint256 nav = poolNavUsd(poolId);
        PriceData memory cp = oracle.getPriceForAction(asset.assetId, pool.maxPriceAge, 0);
        uint256 vaultUsd = _vaultValue(poolId, token, cp.minPrice);
        uint256 grossUsd = MathX.mulDiv(nav, shares, supply);
        if (grossUsd > vaultUsd) revert ExceedsVaultValue();
        uint256 feeUsd =
            _rebaseFeeUsd(false, vaultUsd, _poolVaultsUsd(poolId), grossUsd, asset.targetWeightBps);
        uint256 netUsd = grossUsd > feeUsd ? grossUsd - feeUsd : 0;
        amount = _toToken(netUsd, cp.maxPrice, asset.scale);
        if (amount < minAmount) revert SlippageExceeded();
        if (amount > vault.liquidity) revert InsufficientLiquidity();
        if (vault.minLiquidity != 0 && vault.liquidity - amount < vault.minLiquidity) {
            revert InsufficientLiquidity();
        }
        vault.liquidity -= amount;
        shareToken.burn(msg.sender, shares);
        shareToken.transferToken(token, msg.sender, amount);
        emit LiquidityWithdrawn(msg.sender, poolId, token, amount, shares);
    }

    function swap(
        uint32 poolId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external nonReentrant returns (uint256 amountOut) {
        _checkFn(FN_SWAP);
        if (tokenIn == tokenOut || amountIn == 0) revert InvalidAmount();
        Pool storage pool = _liquidityPool(poolId);
        _accruePool(poolId);
        PoolAsset storage incoming = _asset(poolId, tokenIn);
        PoolAsset storage outgoing = _asset(poolId, tokenOut);
        TokenVault storage inVault = tokenVaults[poolId][tokenIn];
        TokenVault storage outVault = tokenVaults[poolId][tokenOut];
        if (inVault.maxLiquidity != 0 && inVault.liquidity + amountIn > inVault.maxLiquidity) {
            revert InsufficientLiquidity();
        }
        PriceData memory inPrice = oracle.getPriceForAction(incoming.assetId, pool.maxPriceAge, 0);
        PriceData memory outPrice = oracle.getPriceForAction(outgoing.assetId, pool.maxPriceAge, 0);
        uint256 totalUsd = _poolVaultsUsd(poolId);
        uint256 inUsd = _toUsd(amountIn, inPrice.minPrice, incoming.scale);
        uint256 inVaultUsd = _vaultValue(poolId, tokenIn, inPrice.minPrice);
        uint256 inFee = _rebaseFeeUsd(true, inVaultUsd, totalUsd, inUsd, incoming.targetWeightBps);
        uint256 netIn = inUsd > inFee ? inUsd - inFee : 0;
        uint256 outVaultUsd = _vaultValue(poolId, tokenOut, outPrice.minPrice);
        if (netIn >= outVaultUsd) revert ExceedsVaultValue();
        uint256 outFee =
            _rebaseFeeUsd(false, outVaultUsd, totalUsd, netIn, outgoing.targetWeightBps);
        uint256 netUsd = netIn > outFee ? netIn - outFee : 0;
        amountOut = _toToken(netUsd, outPrice.maxPrice, outgoing.scale);
        if (amountOut == 0 || amountOut < minOut || amountOut > outVault.liquidity) {
            revert SlippageExceeded();
        }
        if (outVault.minLiquidity != 0 && outVault.liquidity - amountOut < outVault.minLiquidity) {
            revert InsufficientLiquidity();
        }
        tokenIn.safeTransferFrom(msg.sender, pool.vault, amountIn);
        inVault.liquidity += amountIn;
        outVault.liquidity -= amountOut;
        MarketPoolToken(pool.vault).transferToken(tokenOut, msg.sender, amountOut);
        emit Swapped(msg.sender, poolId, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice LP value is every vault's cash, escrow, and unpaid reserving fee, plus unpaid funding.
    /// Trader margin and open mark-to-market are not included.
    function poolNavUsd(uint32 poolId) public view returns (uint256) {
        _liquidityPool(poolId);
        int256 nav = int256(_poolVaultsUsd(poolId));
        uint256 count = poolMarketIds[poolId].length;
        for (uint256 i; i < count; ++i) {
            Market storage m = markets[poolMarketIds[poolId][i]];
            (,,, int256 longFee, int256 shortFee) = _projectFunding(m);
            nav += longFee + shortFee;
        }
        return nav > 0 ? uint256(nav) : 0;
    }

    function poolTokenPrice(uint32 poolId) external view returns (uint256) {
        MarketPoolToken shareToken = MarketPoolToken(_liquidityPool(poolId).vault);
        uint256 supply = shareToken.totalSupply();
        return supply == 0 ? WAD : MathX.mulDiv(poolNavUsd(poolId), WAD, supply);
    }
}
