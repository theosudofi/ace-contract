// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable2Step } from "./access/Ownable2Step.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { PriceImpactModel } from "./libraries/PriceImpactModel.sol";
import { OracleRouter } from "./oracles/OracleRouter.sol";
import { PerpStore } from "./PerpStore.sol";

/// @notice Perpetuals core. One pool issues one LP token. Each collateral token is its own vault:
/// LP cash, LP coins escrowed on positions, and unpaid reserving fees. Trader margin sits on the
/// position and is outside the LP price. Open mark-to-market is outside the LP price too.
contract AcePerp is PerpStore {
    address public poolLogic;
    address public tradeLogic;

    constructor(
        address initialOwner,
        address guardian_,
        address router_,
        address poolLogic_,
        address tradeLogic_
    ) PerpStore(initialOwner) {
        if (poolLogic_.code.length == 0 || tradeLogic_.code.length == 0) {
            revert InvalidConfig();
        }
        _init(guardian_, router_);
        poolLogic = poolLogic_;
        tradeLogic = tradeLogic_;
    }

    function oracleRouter() external view returns (OracleRouter) {
        return oracle;
    }

    function setPaused(bool value) external onlyGuardian {
        paused = value;
    }

    function setGuardian(address value) external onlyOwner {
        if (value == address(0)) revert InvalidConfig();
        guardian = value;
    }

    function setOrderManager(address value) external onlyOwner {
        if (value != address(0) && value.code.length == 0) revert InvalidConfig();
        orderManager = value;
    }

    function setFeeDestinations(
        address treasury_,
        address insurance_,
        address keeper_,
        FeeConfig calldata config
    ) external onlyOwner {
        if (
            treasury_ == address(0) || insurance_ == address(0) || keeper_ == address(0)
                || uint256(config.treasuryBps) + config.insuranceBps + config.keeperBps > BPS
        ) revert InvalidConfig();
        treasury = treasury_;
        insuranceFund = insurance_;
        keeperFeeReceiver = keeper_;
        feeConfig = config;
        emit FeeDestinationsUpdated(treasury_, insurance_, keeper_, config);
    }

    function setTargetWeights(uint32 poolId, uint16[] calldata weightsBps) external onlyOwner {
        Pool storage pool = _liquidityPool(poolId);
        if (weightsBps.length != pool.assetCount) revert InvalidConfig();
        uint256 total;
        for (uint256 i; i < weightsBps.length; ++i) {
            total += weightsBps[i];
            poolAssets[poolId][uint8(i)].targetWeightBps = weightsBps[i];
        }
        if (total != BPS) revert InvalidConfig();
        emit TargetWeightsUpdated(poolId);
    }

    /// @notice Sets the away-from-target rebase multiplier and a linear exponent. Base stays as set.
    function setImbalanceFee(uint64 feeWad) external onlyOwner {
        if (feeWad > 0.1e18) revert InvalidConfig();
        rebaseMultiplierWad = feeWad;
        rebaseExponent = 1;
        emit ImbalanceFeeUpdated(feeWad);
        emit RebaseFeeUpdated(rebaseBaseWad, feeWad, 1);
    }

    function setRebaseFee(uint64 baseWad, uint64 multiplierWad, uint8 exponent) external onlyOwner {
        if (baseWad > 0.1e18 || multiplierWad > 0.1e18 || exponent < 1 || exponent > 3) {
            revert InvalidConfig();
        }
        rebaseBaseWad = baseWad;
        rebaseMultiplierWad = multiplierWad;
        rebaseExponent = exponent;
        emit RebaseFeeUpdated(baseWad, multiplierWad, exponent);
    }

    function setLossProtection(address vault, uint16 lossCutBps_, uint16 winFundBps_)
        external
        onlyOwner
    {
        if (lossCutBps_ > BPS || winFundBps_ > BPS) revert InvalidConfig();
        if (vault == address(0) && (lossCutBps_ != 0 || winFundBps_ != 0)) revert InvalidConfig();
        lossProtection = vault;
        lossCutBps = lossCutBps_;
        winFundBps = winFundBps_;
        emit LossProtectionUpdated(vault, lossCutBps_, winFundBps_);
    }

    function setFunctionMask(uint256 mask) external onlyOwner {
        functionMask = mask;
        emit FunctionMaskUpdated(mask);
    }

    function migrate(uint32 newVersion, uint256 newMask) external onlyOwner {
        if (newVersion != version + 1) revert VersionMismatch();
        version = newVersion;
        functionMask = newMask;
        emit VersionMigrated(newVersion, newMask);
    }

    function functionEnabled(uint8 id) external view returns (bool) {
        return functionMask & (uint256(1) << id) != 0;
    }

    function createPool(CollateralAsset[] calldata assets, uint32 maxPriceAge)
        external
        onlyOwner
        returns (uint32 id)
    {
        uint256 count = assets.length;
        if (count == 0 || count > MAX_COLLATERAL_ASSETS || maxPriceAge == 0) {
            revert InvalidConfig();
        }
        id = ++poolCount;
        Pool storage pool = pools[id];
        for (uint256 i; i < count; ++i) {
            address token = assets[i].token;
            bytes32 assetId = assets[i].assetId;
            if (token.code.length == 0 || assetId == 0 || poolAssetIndex[id][token] != 0) {
                revert InvalidConfig();
            }
            for (uint256 j; j < i; ++j) {
                if (poolAssets[id][uint8(j)].assetId == assetId) revert DuplicateCollateral();
            }
            uint8 decimals_ = IERC20(token).decimals();
            if (decimals_ > 18) revert InvalidConfig();
            poolAssets[id][uint8(i)] = PoolAsset(token, assetId, 10 ** decimals_, 0);
            poolAssetIndex[id][token] = uint8(i) + 1;
            tokenVaults[id][token].lastReservingTime = uint64(block.timestamp);
        }
        uint16 used;
        uint16 each = uint16(10_000 / count);
        for (uint256 i; i < count; ++i) {
            uint16 weight = i + 1 == count ? uint16(10_000 - used) : each;
            poolAssets[id][uint8(i)].targetWeightBps = weight;
            used += weight;
        }
        pool.assetCount = uint8(count);
        pool.maxPriceAge = maxPriceAge;
        pool.vault = poolFactory.create(address(this));
        emit PoolCreated(id, pool.vault);
    }

    function createMarket(
        uint32 poolId,
        bytes32 assetId,
        MarketConfig calldata config,
        PriceImpactModel.Config calldata impact
    ) external onlyOwner returns (uint32 id) {
        _liquidityPool(poolId);
        if (poolMarketIds[poolId].length >= MAX_MARKETS_PER_POOL) revert TooManyMarkets();
        _validateConfig(assetId, config);
        PriceImpactModel.validate(impact);
        id = ++marketCount;
        Market storage m = markets[id];
        m.assetId = assetId;
        m.poolId = poolId;
        m.enabled = true;
        m.config = config;
        m.priceImpact = impact;
        m.fundingExponent = 1;
        m.maxReservedMultiplier = 10;
        m.longBook.lastUpdate = uint64(block.timestamp);
        m.shortBook.lastUpdate = uint64(block.timestamp);
        poolMarketIds[poolId].push(id);
        emit MarketCreated(id, poolId, assetId);
    }

    function setMarketConfig(uint32 id, MarketConfig calldata config) external onlyOwner {
        Market storage m = _market(id);
        _validateConfig(m.assetId, config);
        m.config = config;
    }

    function setPriceImpactConfig(uint32 id, PriceImpactModel.Config calldata impact)
        external
        onlyOwner
    {
        Market storage m = _market(id);
        PriceImpactModel.validate(impact);
        m.priceImpact = impact;
    }

    function setMarketEnabled(uint32 id, bool value) external onlyGuardian {
        _market(id).enabled = value;
    }

    function poolMarketCount(uint32 poolId) external view returns (uint256) {
        _liquidityPool(poolId);
        return poolMarketIds[poolId].length;
    }

    function poolMarketId(uint32 poolId, uint256 index) external view returns (uint32) {
        _liquidityPool(poolId);
        return poolMarketIds[poolId][index];
    }

    function getMarketOracleConfig(uint32 id, bool opening)
        external
        view
        returns (bytes32 assetId, uint32 maxAge)
    {
        Market storage m = _market(id);
        return (m.assetId, opening ? m.config.maxOpenPriceAge : m.config.maxClosePriceAge);
    }

    function getPoolVault(uint32 poolId) external view returns (address) {
        return _liquidityPool(poolId).vault;
    }

    function depositLiquidity(uint32, address, uint256, uint256) external returns (uint256 shares) {
        bytes memory data = _delegate(poolLogic);
        shares = abi.decode(data, (uint256));
    }

    function withdrawLiquidity(uint32, address, uint256, uint256)
        external
        returns (uint256 amount)
    {
        bytes memory data = _delegate(poolLogic);
        amount = abi.decode(data, (uint256));
    }

    function swap(uint32, address, address, uint256, uint256) external returns (uint256 amountOut) {
        bytes memory data = _delegate(poolLogic);
        amountOut = abi.decode(data, (uint256));
    }

    function poolNavUsd(uint32) external returns (uint256) {
        bytes memory data = _delegate(poolLogic);
        return abi.decode(data, (uint256));
    }

    function poolTokenPrice(uint32) external returns (uint256) {
        bytes memory data = _delegate(poolLogic);
        return abi.decode(data, (uint256));
    }

    function setFundingConfig(uint32, uint8, uint64, uint64, uint8) external {
        _delegate(poolLogic);
    }

    function setReservingFee(uint32, address, uint64) external {
        _delegate(poolLogic);
    }

    function setVaultBounds(uint32, address, uint256, uint256) external {
        _delegate(poolLogic);
    }

    function increasePosition(uint256, uint256, uint256, uint256) external {
        _delegate(tradeLogic);
    }

    function addCollateral(uint256, uint256) external {
        _delegate(tradeLogic);
    }

    function withdrawCollateral(uint256, uint256) external {
        _delegate(tradeLogic);
    }

    function executeOrderIncrease(
        address,
        uint32,
        uint256,
        address,
        uint256,
        uint256,
        bool,
        uint256,
        uint256,
        address
    ) external returns (uint256 id) {
        bytes memory data = _delegate(tradeLogic);
        id = abi.decode(data, (uint256));
    }

    function executeOrderDecrease(address, uint256, uint256, uint256, uint256, address)
        external
        returns (uint256 payout)
    {
        bytes memory data = _delegate(tradeLogic);
        payout = abi.decode(data, (uint256));
    }

    function liquidate(uint256) external returns (uint256 reward) {
        bytes memory data = _delegate(tradeLogic);
        reward = abi.decode(data, (uint256));
    }

    function positionEquityUsd(uint256) external returns (int256 equity, uint256 mark) {
        bytes memory data = _delegate(tradeLogic);
        (equity, mark) = abi.decode(data, (int256, uint256));
    }

    function _delegate(address logic) private returns (bytes memory) {
        (bool ok, bytes memory data) = logic.delegatecall(msg.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(data, 32), mload(data))
            }
        }
        return data;
    }
}
