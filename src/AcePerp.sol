// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable2Step } from "./access/Ownable2Step.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { MathX } from "./libraries/MathX.sol";
import { PriceImpactModel } from "./libraries/PriceImpactModel.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { OracleRouter } from "./oracles/OracleRouter.sol";

/// @title AcePerp
/// @notice Compact, isolated-margin perpetuals core designed for Robinhood Chain.
/// @dev The first EVM release intentionally uses one settlement token and direct market execution.
contract AcePerp is Ownable2Step {
    using SafeTransferLib for address;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

    struct MarketConfig {
        uint128 maxOiUsd;
        uint128 minPositionSizeUsd;
        uint128 maxLeverageWad;
        uint64 maxPriceAge;
        uint64 maintenanceMarginWad;
        uint64 tradeFeeWad;
        uint64 liquidationFeeWad;
        uint64 fundingFactorPerSecondWad;
    }

    struct Market {
        bytes32 assetId;
        bool enabled;
        MarketConfig config;
        PriceImpactModel.Config priceImpact;
        uint256 longOiUsd;
        uint256 shortOiUsd;
        int256 cumulativeFundingIndex;
        uint64 lastFundingTime;
    }

    struct Position {
        address owner;
        uint32 marketId;
        bool isLong;
        uint256 collateralAmount;
        uint256 sizeUsd;
        uint256 entryPrice;
        int256 entryFundingIndex;
    }

    error InvalidConfig();
    error InvalidAmount();
    error MarketNotFound();
    error MarketDisabled();
    error ProtocolPaused();
    error SlippageExceeded();
    error MaxOpenInterestExceeded();
    error MaxLeverageExceeded();
    error PositionNotFound();
    error NotPositionOwner();
    error PositionHealthy();
    error InsufficientLiquidity();
    error ReserveRequirement();
    error Reentrancy();
    error UnauthorizedGuardian();

    IERC20 public immutable collateralToken;
    uint8 public immutable collateralDecimals;
    uint256 public immutable collateralScale;
    bytes32 public immutable collateralAssetId;
    OracleRouter public immutable oracleRouter;

    address public guardian;
    bool public paused;
    uint64 public minLiquidityReserveRateWad = 0.1e18;

    uint32 public marketCount;
    uint256 public nextPositionId = 1;
    uint256 public poolLiquidity;
    uint256 public totalLpShares;
    uint256 public totalOpenInterestUsd;
    uint256 private _entered = 1;

    mapping(uint32 marketId => Market) public markets;
    mapping(uint256 positionId => Position) public positions;
    mapping(address account => uint256 shares) public lpShares;

    event GuardianUpdated(address indexed guardian);
    event Paused(bool paused);
    event MarketCreated(uint32 indexed marketId, bytes32 indexed assetId);
    event MarketStatusUpdated(uint32 indexed marketId, bool enabled);
    event MarketConfigUpdated(uint32 indexed marketId);
    event PriceImpactConfigUpdated(uint32 indexed marketId);
    event LiquidityDeposited(address indexed provider, uint256 assets, uint256 shares);
    event LiquidityWithdrawn(address indexed provider, uint256 assets, uint256 shares);
    event PositionOpened(
        uint256 indexed positionId,
        address indexed trader,
        uint32 indexed marketId,
        bool isLong,
        uint256 sizeUsd,
        uint256 collateralAmount,
        uint256 executionPrice,
        int256 impactRateWad
    );
    event PositionDecreased(
        uint256 indexed positionId,
        uint256 sizeClosedUsd,
        uint256 executionPrice,
        int256 pnlUsd,
        int256 fundingFeeUsd,
        uint256 feeUsd,
        uint256 payoutAmount,
        int256 impactRateWad
    );
    event PositionLiquidated(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 markPrice,
        int256 equityUsd,
        uint256 liquidatorReward
    );
    event FundingUpdated(uint32 indexed marketId, int256 cumulativeFundingIndex);

    constructor(
        address initialOwner,
        address guardian_,
        address collateralToken_,
        bytes32 collateralAssetId_,
        address oracleRouter_
    ) Ownable2Step(initialOwner) {
        if (
            guardian_ == address(0) || collateralToken_ == address(0)
                || collateralAssetId_ == bytes32(0) || oracleRouter_ == address(0)
                || collateralToken_.code.length == 0 || oracleRouter_.code.length == 0
        ) revert InvalidConfig();
        uint8 decimals_ = IERC20(collateralToken_).decimals();
        if (decimals_ > 18) revert InvalidConfig();
        guardian = guardian_;
        collateralToken = IERC20(collateralToken_);
        collateralDecimals = decimals_;
        collateralScale = 10 ** decimals_;
        collateralAssetId = collateralAssetId_;
        oracleRouter = OracleRouter(oracleRouter_);
    }

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner) revert UnauthorizedGuardian();
        _;
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert InvalidConfig();
        guardian = guardian_;
        emit GuardianUpdated(guardian_);
    }

    function setPaused(bool paused_) external onlyGuardianOrOwner {
        paused = paused_;
        emit Paused(paused_);
    }

    function setMinLiquidityReserveRate(uint64 rateWad) external onlyOwner {
        if (rateWad > WAD) revert InvalidConfig();
        minLiquidityReserveRateWad = rateWad;
    }

    function createMarket(
        bytes32 assetId,
        MarketConfig calldata config,
        PriceImpactModel.Config calldata impactConfig
    ) external onlyOwner returns (uint32 marketId) {
        _validateMarketConfig(assetId, config);
        PriceImpactModel.validate(impactConfig);
        marketId = ++marketCount;
        Market storage market = markets[marketId];
        market.assetId = assetId;
        market.enabled = true;
        market.config = config;
        market.priceImpact = impactConfig;
        market.lastFundingTime = uint64(block.timestamp);
        emit MarketCreated(marketId, assetId);
    }

    function setMarketConfig(uint32 marketId, MarketConfig calldata config) external onlyOwner {
        Market storage market = _market(marketId);
        _validateMarketConfig(market.assetId, config);
        if (market.longOiUsd > config.maxOiUsd || market.shortOiUsd > config.maxOiUsd) {
            revert MaxOpenInterestExceeded();
        }
        _updateFunding(marketId, market);
        market.config = config;
        emit MarketConfigUpdated(marketId);
    }

    function setPriceImpactConfig(uint32 marketId, PriceImpactModel.Config calldata config)
        external
        onlyOwner
    {
        PriceImpactModel.validate(config);
        markets[marketId].priceImpact = config;
        if (markets[marketId].assetId == bytes32(0)) revert MarketNotFound();
        emit PriceImpactConfigUpdated(marketId);
    }

    function setMarketEnabled(uint32 marketId, bool enabled) external onlyGuardianOrOwner {
        Market storage market = _market(marketId);
        market.enabled = enabled;
        emit MarketStatusUpdated(marketId, enabled);
    }

    // -------------------------------------------------------------------------
    // Liquidity
    // -------------------------------------------------------------------------

    function depositLiquidity(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert InvalidAmount();
        uint256 liquidityBefore = poolLiquidity;
        shares = totalLpShares == 0 ? amount : MathX.mulDiv(amount, totalLpShares, liquidityBefore);
        if (shares == 0) revert InvalidAmount();
        address(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        poolLiquidity = liquidityBefore + amount;
        totalLpShares += shares;
        lpShares[msg.sender] += shares;
        emit LiquidityDeposited(msg.sender, amount, shares);
    }

    function withdrawLiquidity(uint256 shares, uint256 minAmount)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (shares == 0 || shares > lpShares[msg.sender]) revert InvalidAmount();
        amount = MathX.mulDiv(shares, poolLiquidity, totalLpShares);
        if (amount < minAmount) revert SlippageExceeded();
        uint256 remaining = poolLiquidity - amount;
        (uint256 collateralPrice,) = oracleRouter.getPrice(collateralAssetId, 1 hours);
        uint256 remainingUsd = _tokenToUsd(remaining, collateralPrice);
        uint256 requiredUsd = MathX.mulDiv(totalOpenInterestUsd, minLiquidityReserveRateWad, WAD);
        if (remainingUsd < requiredUsd) revert ReserveRequirement();
        lpShares[msg.sender] -= shares;
        totalLpShares -= shares;
        poolLiquidity = remaining;
        address(collateralToken).safeTransfer(msg.sender, amount);
        emit LiquidityWithdrawn(msg.sender, amount, shares);
    }

    // -------------------------------------------------------------------------
    // Trading
    // -------------------------------------------------------------------------

    /// @param acceptablePrice Maximum execution price for longs, minimum for shorts.
    function openPosition(
        uint32 marketId,
        uint256 collateralAmount,
        uint256 sizeUsd,
        bool isLong,
        uint256 acceptablePrice
    ) external nonReentrant returns (uint256 positionId) {
        if (paused) revert ProtocolPaused();
        Market storage market = _market(marketId);
        if (!market.enabled) revert MarketDisabled();
        if (collateralAmount == 0 || sizeUsd < market.config.minPositionSizeUsd) {
            revert InvalidAmount();
        }

        _updateFunding(marketId, market);
        (uint256 oraclePrice,) = oracleRouter.getPrice(market.assetId, market.config.maxPriceAge);
        PriceImpactModel.Quote memory impact = PriceImpactModel.quote(
            market.priceImpact,
            oraclePrice,
            market.longOiUsd,
            market.shortOiUsd,
            market.config.maxOiUsd,
            sizeUsd,
            isLong,
            true
        );
        _checkSlippage(impact.executionPrice, acceptablePrice, isLong);
        if (
            impact.longOiAfter > market.config.maxOiUsd
                || impact.shortOiAfter > market.config.maxOiUsd
        ) revert MaxOpenInterestExceeded();

        (uint256 collateralPrice,) =
            oracleRouter.getPrice(collateralAssetId, market.config.maxPriceAge);
        uint256 feeUsd = MathX.mulDivUp(sizeUsd, market.config.tradeFeeWad, WAD);
        uint256 feeAmount = _usdToTokenUp(feeUsd, collateralPrice);
        if (feeAmount >= collateralAmount) revert MaxLeverageExceeded();
        uint256 netCollateral = collateralAmount - feeAmount;
        uint256 collateralUsd = _tokenToUsd(netCollateral, collateralPrice);
        if (
            sizeUsd > MathX.mulDiv(collateralUsd, market.config.maxLeverageWad, WAD)
                || collateralUsd <= MathX.mulDiv(sizeUsd, market.config.maintenanceMarginWad, WAD)
        ) revert MaxLeverageExceeded();
        uint256 poolUsdAfterFee = _tokenToUsd(poolLiquidity + feeAmount, collateralPrice);
        uint256 requiredPoolUsd =
            MathX.mulDiv(totalOpenInterestUsd + sizeUsd, minLiquidityReserveRateWad, WAD);
        if (poolUsdAfterFee < requiredPoolUsd) revert ReserveRequirement();

        address(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        poolLiquidity += feeAmount;
        positionId = nextPositionId++;
        positions[positionId] = Position({
            owner: msg.sender,
            marketId: marketId,
            isLong: isLong,
            collateralAmount: netCollateral,
            sizeUsd: sizeUsd,
            entryPrice: impact.executionPrice,
            entryFundingIndex: market.cumulativeFundingIndex
        });
        market.longOiUsd = impact.longOiAfter;
        market.shortOiUsd = impact.shortOiAfter;
        totalOpenInterestUsd += sizeUsd;
        emit PositionOpened(
            positionId,
            msg.sender,
            marketId,
            isLong,
            sizeUsd,
            netCollateral,
            impact.executionPrice,
            impact.impactRateWad
        );
    }

    /// @param acceptablePrice Minimum execution price for closing longs, maximum for closing shorts.
    function decreasePosition(uint256 positionId, uint256 sizeUsd, uint256 acceptablePrice)
        external
        nonReentrant
        returns (uint256 payoutAmount)
    {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        if (position.owner != msg.sender) revert NotPositionOwner();
        if (sizeUsd == 0 || sizeUsd > position.sizeUsd) revert InvalidAmount();

        Market storage market = markets[position.marketId];
        _updateFunding(position.marketId, market);
        (uint256 oraclePrice,) = oracleRouter.getPrice(market.assetId, market.config.maxPriceAge);
        PriceImpactModel.Quote memory impact = PriceImpactModel.quote(
            market.priceImpact,
            oraclePrice,
            market.longOiUsd,
            market.shortOiUsd,
            market.config.maxOiUsd,
            sizeUsd,
            position.isLong,
            false
        );
        _checkSlippage(impact.executionPrice, acceptablePrice, !position.isLong);

        uint256 oldSize = position.sizeUsd;
        uint256 collateralReleased = MathX.mulDiv(position.collateralAmount, sizeUsd, oldSize);
        int256 pnlUsd = _pnl(sizeUsd, position.entryPrice, impact.executionPrice, position.isLong);
        int256 fundingFeeUsd = _fundingFee(position, market.cumulativeFundingIndex, sizeUsd);
        uint256 feeUsd = MathX.mulDivUp(sizeUsd, market.config.tradeFeeWad, WAD);
        (uint256 collateralPrice,) =
            oracleRouter.getPrice(collateralAssetId, market.config.maxPriceAge);
        int256 equityUsd = int256(_tokenToUsd(collateralReleased, collateralPrice)) + pnlUsd
            - fundingFeeUsd - int256(feeUsd);
        payoutAmount = equityUsd <= 0 ? 0 : _usdToToken(uint256(equityUsd), collateralPrice);
        _settle(position.owner, collateralReleased, payoutAmount);

        position.sizeUsd = oldSize - sizeUsd;
        position.collateralAmount -= collateralReleased;
        market.longOiUsd = impact.longOiAfter;
        market.shortOiUsd = impact.shortOiAfter;
        totalOpenInterestUsd -= sizeUsd;
        if (position.sizeUsd == 0) delete positions[positionId];

        emit PositionDecreased(
            positionId,
            sizeUsd,
            impact.executionPrice,
            pnlUsd,
            fundingFeeUsd,
            feeUsd,
            payoutAmount,
            impact.impactRateWad
        );
    }

    function liquidate(uint256 positionId) external nonReentrant returns (uint256 rewardAmount) {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        Market storage market = markets[position.marketId];
        _updateFunding(position.marketId, market);
        (uint256 markPrice,) = oracleRouter.getPrice(market.assetId, market.config.maxPriceAge);
        (uint256 collateralPrice,) =
            oracleRouter.getPrice(collateralAssetId, market.config.maxPriceAge);

        int256 pnlUsd = _pnl(position.sizeUsd, position.entryPrice, markPrice, position.isLong);
        int256 fundingFeeUsd =
            _fundingFee(position, market.cumulativeFundingIndex, position.sizeUsd);
        int256 equityUsd = int256(_tokenToUsd(position.collateralAmount, collateralPrice)) + pnlUsd
            - fundingFeeUsd;
        uint256 maintenanceUsd =
            MathX.mulDiv(position.sizeUsd, market.config.maintenanceMarginWad, WAD);
        if (equityUsd > int256(maintenanceUsd)) revert PositionHealthy();

        uint256 liquidationFeeUsd =
            MathX.mulDiv(position.sizeUsd, market.config.liquidationFeeWad, WAD);
        uint256 positiveEquity = equityUsd > 0 ? uint256(equityUsd) : 0;
        uint256 rewardUsd = MathX.min(positiveEquity, liquidationFeeUsd);
        uint256 userPayoutUsd = positiveEquity - rewardUsd;
        rewardAmount = _usdToToken(rewardUsd, collateralPrice);
        uint256 userPayout = _usdToToken(userPayoutUsd, collateralPrice);

        uint256 collateralAmount = position.collateralAmount;
        address positionOwner = position.owner;
        uint256 size = position.sizeUsd;
        if (position.isLong) market.longOiUsd -= size;
        else market.shortOiUsd -= size;
        totalOpenInterestUsd -= size;
        delete positions[positionId];
        _settleTwo(positionOwner, msg.sender, collateralAmount, userPayout, rewardAmount);
        emit PositionLiquidated(positionId, msg.sender, markPrice, equityUsd, rewardAmount);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function previewExecutionPrice(uint32 marketId, uint256 sizeUsd, bool isLong, bool isIncrease)
        external
        view
        returns (PriceImpactModel.Quote memory)
    {
        Market storage market = markets[marketId];
        if (market.assetId == bytes32(0)) revert MarketNotFound();
        (uint256 oraclePrice,) = oracleRouter.getPrice(market.assetId, market.config.maxPriceAge);
        return PriceImpactModel.quote(
            market.priceImpact,
            oraclePrice,
            market.longOiUsd,
            market.shortOiUsd,
            market.config.maxOiUsd,
            sizeUsd,
            isLong,
            isIncrease
        );
    }

    function positionEquityUsd(uint256 positionId)
        external
        view
        returns (int256 equityUsd, uint256 markPrice)
    {
        Position storage position = positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        Market storage market = markets[position.marketId];
        (markPrice,) = oracleRouter.getPrice(market.assetId, market.config.maxPriceAge);
        (uint256 collateralPrice,) =
            oracleRouter.getPrice(collateralAssetId, market.config.maxPriceAge);
        int256 projectedIndex = _projectFundingIndex(market);
        equityUsd = int256(_tokenToUsd(position.collateralAmount, collateralPrice))
            + _pnl(position.sizeUsd, position.entryPrice, markPrice, position.isLong)
            - _fundingFee(position, projectedIndex, position.sizeUsd);
    }

    // -------------------------------------------------------------------------
    // Internal accounting
    // -------------------------------------------------------------------------

    function _validateMarketConfig(bytes32 assetId, MarketConfig calldata config) private pure {
        if (
            assetId == bytes32(0) || config.maxOiUsd == 0 || config.minPositionSizeUsd == 0
                || config.maxLeverageWad < WAD || config.maxLeverageWad > 100e18
                || config.maxPriceAge == 0 || config.maintenanceMarginWad == 0
                || config.maintenanceMarginWad > 0.5e18 || config.tradeFeeWad > 0.05e18
                || config.liquidationFeeWad > 0.1e18 || config.fundingFactorPerSecondWad > 0.001e18
        ) revert InvalidConfig();
    }

    function _market(uint32 marketId) private view returns (Market storage market) {
        market = markets[marketId];
        if (market.assetId == bytes32(0)) revert MarketNotFound();
    }

    function _updateFunding(uint32 marketId, Market storage market) private {
        int256 projected = _projectFundingIndex(market);
        if (projected != market.cumulativeFundingIndex) {
            market.cumulativeFundingIndex = projected;
            emit FundingUpdated(marketId, projected);
        }
        market.lastFundingTime = uint64(block.timestamp);
    }

    function _projectFundingIndex(Market storage market) private view returns (int256) {
        uint256 elapsed = block.timestamp - market.lastFundingTime;
        if (elapsed == 0 || market.config.fundingFactorPerSecondWad == 0) {
            return market.cumulativeFundingIndex;
        }
        int256 skew = int256(market.longOiUsd) - int256(market.shortOiUsd);
        int256 skewRatio = skew >= 0
            ? int256(MathX.mulDiv(uint256(skew), WAD, market.config.maxOiUsd))
            : -int256(MathX.mulDiv(uint256(-skew), WAD, market.config.maxOiUsd));
        int256 ratePerSecond =
            _mulDivSigned(uint256(market.config.fundingFactorPerSecondWad), skewRatio, WAD);
        return market.cumulativeFundingIndex + ratePerSecond * int256(elapsed);
    }

    function _fundingFee(Position storage position, int256 currentIndex, uint256 sizeUsd)
        private
        view
        returns (int256)
    {
        int256 delta = currentIndex - position.entryFundingIndex;
        int256 fee = _mulDivSigned(sizeUsd, delta, WAD);
        return position.isLong ? fee : -fee;
    }

    function _pnl(uint256 sizeUsd, uint256 entryPrice, uint256 exitPrice, bool isLong)
        private
        pure
        returns (int256)
    {
        int256 difference = int256(exitPrice) - int256(entryPrice);
        int256 longPnl = _mulDivSigned(sizeUsd, difference, entryPrice);
        return isLong ? longPnl : -longPnl;
    }

    function _mulDivSigned(uint256 magnitude, int256 signedValue, uint256 denominator)
        private
        pure
        returns (int256)
    {
        if (signedValue >= 0) {
            return int256(MathX.mulDiv(magnitude, uint256(signedValue), denominator));
        }
        return -int256(MathX.mulDiv(magnitude, uint256(-signedValue), denominator));
    }

    function _checkSlippage(uint256 executionPrice, uint256 acceptablePrice, bool isBuy)
        private
        pure
    {
        if (acceptablePrice == 0) revert SlippageExceeded();
        if (isBuy ? executionPrice > acceptablePrice : executionPrice < acceptablePrice) {
            revert SlippageExceeded();
        }
    }

    function _tokenToUsd(uint256 amount, uint256 priceWad) private view returns (uint256) {
        return MathX.mulDiv(amount, priceWad, collateralScale);
    }

    function _usdToToken(uint256 usdWad, uint256 priceWad) private view returns (uint256) {
        return MathX.mulDiv(usdWad, collateralScale, priceWad);
    }

    function _usdToTokenUp(uint256 usdWad, uint256 priceWad) private view returns (uint256) {
        return MathX.mulDivUp(usdWad, collateralScale, priceWad);
    }

    function _settle(address recipient, uint256 collateralReleased, uint256 payout) private {
        uint256 available = poolLiquidity + collateralReleased;
        if (payout > available) revert InsufficientLiquidity();
        poolLiquidity = available - payout;
        if (payout != 0) address(collateralToken).safeTransfer(recipient, payout);
    }

    function _settleTwo(
        address user,
        address liquidator,
        uint256 collateralReleased,
        uint256 userPayout,
        uint256 reward
    ) private {
        uint256 totalPayout = userPayout + reward;
        uint256 available = poolLiquidity + collateralReleased;
        if (totalPayout > available) revert InsufficientLiquidity();
        poolLiquidity = available - totalPayout;
        if (userPayout != 0) address(collateralToken).safeTransfer(user, userPayout);
        if (reward != 0) address(collateralToken).safeTransfer(liquidator, reward);
    }
}
