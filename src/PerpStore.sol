// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable2Step } from "./access/Ownable2Step.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { PriceData } from "./interfaces/IPriceAdapter.sol";
import { MathX } from "./libraries/MathX.sol";
import { PriceImpactModel } from "./libraries/PriceImpactModel.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { MarketPoolToken } from "./market/MarketPoolToken.sol";
import { MarketPoolFactory } from "./market/MarketPoolFactory.sol";
import { OracleRouter } from "./oracles/OracleRouter.sol";

/// @notice Perpetuals core. One pool issues one LP token. Each collateral token is its own vault:
/// LP cash, LP coins escrowed on positions, and unpaid reserving fees. Trader margin sits on the
/// position and is outside the LP price. Open mark-to-market is outside the LP price too.
abstract contract PerpStore is Ownable2Step {
    using SafeTransferLib for address;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant EIGHT_HOURS = 28_800;
    uint8 public constant MAX_COLLATERAL_ASSETS = 8;
    uint8 public constant MAX_MARKETS_PER_POOL = 16;
    uint8 public constant FN_DEPOSIT = 0;
    uint8 public constant FN_WITHDRAW = 1;
    uint8 public constant FN_OPEN = 2;
    uint8 public constant FN_DECREASE = 3;
    uint8 public constant FN_LIQUIDATE = 4;
    uint8 public constant FN_SWAP = 5;
    uint8 public constant FN_INCREASE = 6;

    struct CollateralAsset {
        address token;
        bytes32 assetId;
    }

    struct PoolAsset {
        address token;
        bytes32 assetId;
        uint256 scale;
        uint16 targetWeightBps;
    }

    struct Pool {
        uint8 assetCount;
        uint32 maxPriceAge;
        address vault;
    }

    /// @dev `liquidity` and `reserved` are token units. `unrealisedReservingFee` is token units
    /// times WAD, so a fractional fee still counts in the LP price.
    struct TokenVault {
        uint256 liquidity;
        uint256 reserved;
        uint256 unrealisedReservingFee;
        uint256 accReservingRate;
        uint64 lastReservingTime;
        uint64 reservingMultiplierWad;
        uint256 minLiquidity;
        uint256 maxLiquidity;
    }

    struct MarketConfig {
        uint128 maxOiUsd;
        uint128 minPositionSizeUsd;
        uint128 maxLeverageWad;
        uint32 maxOpenPriceAge;
        uint32 maxClosePriceAge;
        uint32 maxLiquidationPriceAge;
        uint64 maintenanceMarginWad;
        uint64 tradeFeeWad;
        uint64 liquidationFeeWad;
        uint64 borrowingFactorPerSecondWad;
        uint64 reserveFactorWad;
    }

    /// @dev One book per direction. Long and short share the LP vaults and keep separate funding.
    struct SideBook {
        int256 realisedPnlUsd;
        int256 unrealisedFundingUsd;
        int256 accFundingRate;
        uint64 lastUpdate;
    }

    struct Market {
        bytes32 assetId;
        uint32 poolId;
        bool enabled;
        MarketConfig config;
        PriceImpactModel.Config priceImpact;
        uint256 longOiUsd;
        uint256 shortOiUsd;
        uint256 longSizeTokens;
        uint256 shortSizeTokens;
        uint8 fundingMode;
        uint64 fundingMultiplierWad;
        uint64 fundingMaxRateWad;
        uint8 fundingExponent;
        uint64 maxReservedMultiplier;
        SideBook longBook;
        SideBook shortBook;
    }

    struct Position {
        address owner;
        uint32 marketId;
        bool isLong;
        address collateralToken;
        uint256 collateralAmount;
        uint256 reservedAmount;
        uint256 sizeUsd;
        uint256 sizeTokens;
        uint256 entryPrice;
        uint256 entryReservingRate;
        int256 entryFundingIndex;
    }

    struct FeeConfig {
        uint16 treasuryBps;
        uint16 insuranceBps;
        uint16 keeperBps;
    }

    error InvalidConfig();
    error InvalidAmount();
    error PoolNotFound();
    error TooManyMarkets();
    error DuplicateCollateral();
    error UnsupportedCollateral();
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
    error ExceedsVaultValue();
    error Reentrancy();
    error UnauthorizedCaller();
    error MarketClosed();
    error FunctionDisabled(uint8 id);
    error VersionMismatch();

    OracleRouter internal oracle;
    MarketPoolFactory internal poolFactory;
    address public guardian;
    address public orderManager;
    address public treasury;
    address public insuranceFund;
    address public keeperFeeReceiver;
    bool public paused;
    FeeConfig public feeConfig;
    uint64 public rebaseBaseWad;
    uint64 public rebaseMultiplierWad;
    uint8 public rebaseExponent = 1;
    address public lossProtection;
    uint16 public lossCutBps;
    uint16 public winFundBps;
    uint256 public functionMask;
    uint32 public version = 1;
    uint32 public poolCount;
    uint32 public marketCount;
    uint256 public nextPositionId = 1;
    uint256 private entered = 1;
    mapping(uint32 => Pool) public pools;
    mapping(uint32 => mapping(uint8 => PoolAsset)) public poolAssets;
    mapping(uint32 => mapping(address => uint8)) internal poolAssetIndex;
    mapping(uint32 => uint32[]) internal poolMarketIds;
    mapping(uint32 => mapping(address => TokenVault)) public tokenVaults;
    mapping(uint32 => Market) public markets;
    mapping(uint256 => Position) public positions;

    event PoolCreated(uint32 indexed poolId, address vault);
    event MarketCreated(uint32 indexed marketId, uint32 indexed poolId, bytes32 indexed assetId);
    event LiquidityDeposited(
        address indexed provider,
        uint32 indexed poolId,
        address indexed token,
        uint256 assets,
        uint256 shares
    );
    event LiquidityWithdrawn(
        address indexed provider,
        uint32 indexed poolId,
        address indexed token,
        uint256 assets,
        uint256 shares
    );
    event PositionOpened(
        uint256 indexed id,
        address indexed owner,
        uint32 indexed marketId,
        bool isLong,
        address collateralToken,
        uint256 sizeUsd,
        uint256 collateral,
        uint256 price
    );
    event PositionIncreased(
        uint256 indexed id, uint256 sizeDeltaUsd, uint256 collateralDelta, uint256 price
    );
    event PositionDecreased(
        uint256 indexed id, uint256 sizeDeltaUsd, uint256 payout, uint256 price
    );
    event CollateralChanged(uint256 indexed id, int256 amount);
    event PositionLiquidated(uint256 indexed id, address indexed liquidator, uint256 reward);
    event FeeDestinationsUpdated(
        address treasury, address insurance, address keeper, FeeConfig config
    );
    event FundingConfigUpdated(
        uint32 indexed marketId, uint8 mode, uint64 multiplierWad, uint64 maxRateWad, uint8 exponent
    );
    event TargetWeightsUpdated(uint32 indexed poolId);
    event ImbalanceFeeUpdated(uint64 feeWad);
    event RebaseFeeUpdated(uint64 baseWad, uint64 multiplierWad, uint8 exponent);
    event ReservingFeeUpdated(uint32 indexed poolId, address indexed token, uint64 multiplierWad);
    event VaultBoundsUpdated(
        uint32 indexed poolId, address indexed token, uint256 minLiquidity, uint256 maxLiquidity
    );
    event LossProtectionUpdated(address vault, uint16 lossCutBps, uint16 winFundBps);
    event FunctionMaskUpdated(uint256 mask);
    event VersionMigrated(uint32 version, uint256 mask);
    event Swapped(
        address indexed account,
        uint32 indexed poolId,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address initialOwner) Ownable2Step(initialOwner) { }

    function _init(address guardian_, address router_) internal {
        if (guardian_ == address(0) || router_.code.length == 0) revert InvalidConfig();
        guardian = guardian_;
        oracle = OracleRouter(router_);
        treasury = owner;
        poolFactory = new MarketPoolFactory();
        insuranceFund = owner;
        keeperFeeReceiver = owner;
        feeConfig = FeeConfig(1500, 1000, 500);
        functionMask = type(uint256).max;
    }

    modifier nonReentrant() {
        if (entered != 1) revert Reentrancy();
        entered = 2;
        _;
        entered = 1;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != owner) revert UnauthorizedCaller();
        _;
    }

    function _open(
        address account,
        address payer,
        uint32 id,
        address collateralToken,
        uint256 collateral,
        uint256 size,
        bool isLong,
        uint256 acceptable,
        uint256 submittedAt
    ) internal returns (uint256 positionId) {
        if (paused) revert ProtocolPaused();
        Market storage m = _market(id);
        if (!m.enabled) revert MarketDisabled();
        _asset(m.poolId, collateralToken);
        TokenVault storage vault = tokenVaults[m.poolId][collateralToken];
        _accrueVault(vault);
        _accrueFunding(m);
        if (collateral == 0 || size < m.config.minPositionSizeUsd) revert InvalidAmount();
        (PriceData memory ip, PriceData memory cp, uint256 scale) =
            _prices(m, collateralToken, true, submittedAt);
        uint256 oraclePrice = isLong ? ip.maxPrice : ip.minPrice;
        PriceImpactModel.Quote memory q = PriceImpactModel.quote(
            m.priceImpact,
            oraclePrice,
            m.longOiUsd,
            m.shortOiUsd,
            m.config.maxOiUsd,
            size,
            isLong,
            true
        );
        _slippage(q.executionPrice, acceptable, isLong);
        if (q.longOiAfter > m.config.maxOiUsd || q.shortOiAfter > m.config.maxOiUsd) {
            revert MaxOpenInterestExceeded();
        }
        MarketPoolToken pool = _vault(m);
        collateralToken.safeTransferFrom(payer, address(pool), collateral);
        uint256 fee = _toToken(MathX.mulDivUp(size, m.config.tradeFeeWad, WAD), cp.minPrice, scale);
        if (fee >= collateral) revert MaxLeverageExceeded();
        uint256 net = collateral - fee;
        vault.liquidity += _routeFee(pool, collateralToken, fee, address(0));
        uint256 reserveTokens = _reserveFor(m, size, net, cp.maxPrice, scale);
        if (reserveTokens != 0 && vault.liquidity <= reserveTokens) revert InsufficientLiquidity();
        vault.liquidity -= reserveTokens;
        vault.reserved += reserveTokens;
        positionId = nextPositionId++;
        uint256 sizeTokens = MathX.mulDiv(size, WAD, q.executionPrice);
        int256 entryFunding = _book(m, isLong).accFundingRate;
        positions[positionId] = Position(
            account,
            id,
            isLong,
            collateralToken,
            net,
            reserveTokens,
            size,
            sizeTokens,
            q.executionPrice,
            vault.accReservingRate,
            entryFunding
        );
        _addSize(m, isLong, sizeTokens);
        m.longOiUsd = q.longOiAfter;
        m.shortOiUsd = q.shortOiAfter;
        _requireHealthy(positions[positionId], m);
        emit PositionOpened(
            positionId, account, id, isLong, collateralToken, size, net, q.executionPrice
        );
    }

    function _increase(
        Position storage p,
        uint256 id,
        address payer,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 acceptable,
        uint256 submittedAt
    ) internal {
        if (paused) revert ProtocolPaused();
        if (collateralDelta == 0 && sizeDelta == 0) revert InvalidAmount();
        Market storage m = markets[p.marketId];
        if (!m.enabled) revert MarketDisabled();
        TokenVault storage vault = tokenVaults[m.poolId][p.collateralToken];
        _accrueVault(vault);
        _accrueFunding(m);
        (PriceData memory ip, PriceData memory cp, uint256 scale) =
            _prices(m, p.collateralToken, true, submittedAt);
        _settleFees(m, vault, p, cp.minPrice, scale);
        MarketPoolToken pool = _vault(m);
        if (collateralDelta != 0) {
            p.collateralToken.safeTransferFrom(payer, address(pool), collateralDelta);
            p.collateralAmount += collateralDelta;
        }
        uint256 price = p.entryPrice;
        if (sizeDelta != 0) {
            PriceImpactModel.Quote memory q = PriceImpactModel.quote(
                m.priceImpact,
                p.isLong ? ip.maxPrice : ip.minPrice,
                m.longOiUsd,
                m.shortOiUsd,
                m.config.maxOiUsd,
                sizeDelta,
                p.isLong,
                true
            );
            _slippage(q.executionPrice, acceptable, p.isLong);
            if (q.longOiAfter > m.config.maxOiUsd || q.shortOiAfter > m.config.maxOiUsd) {
                revert MaxOpenInterestExceeded();
            }
            uint256 fee =
                _toToken(MathX.mulDivUp(sizeDelta, m.config.tradeFeeWad, WAD), cp.minPrice, scale);
            if (fee >= p.collateralAmount) revert MaxLeverageExceeded();
            p.collateralAmount -= fee;
            vault.liquidity += _routeFee(pool, p.collateralToken, fee, p.owner);
            uint256 moreReserve = _reserveFor(m, sizeDelta, p.collateralAmount, cp.maxPrice, scale);
            if (moreReserve != 0 && vault.liquidity <= moreReserve) revert InsufficientLiquidity();
            vault.liquidity -= moreReserve;
            vault.reserved += moreReserve;
            p.reservedAmount += moreReserve;
            uint256 addedTokens = MathX.mulDiv(sizeDelta, WAD, q.executionPrice);
            p.sizeUsd += sizeDelta;
            p.sizeTokens += addedTokens;
            p.entryPrice = MathX.mulDiv(p.sizeUsd, WAD, p.sizeTokens);
            _addSize(m, p.isLong, addedTokens);
            m.longOiUsd = q.longOiAfter;
            m.shortOiUsd = q.shortOiAfter;
            price = q.executionPrice;
        }
        p.entryReservingRate = vault.accReservingRate;
        p.entryFundingIndex = _book(m, p.isLong).accFundingRate;
        _requireHealthy(p, m);
        emit PositionIncreased(id, sizeDelta, collateralDelta, price);
    }

    function _decrease(
        Position storage p,
        uint256 id,
        address account,
        uint256 sizeDelta,
        uint256 acceptable,
        uint256 submittedAt,
        address keeper
    ) internal returns (uint256 payout) {
        if (sizeDelta == 0 || sizeDelta > p.sizeUsd) revert InvalidAmount();
        Market storage m = markets[p.marketId];
        TokenVault storage vault = tokenVaults[m.poolId][p.collateralToken];
        _accrueVault(vault);
        _accrueFunding(m);
        (PriceData memory ip, PriceData memory cp, uint256 scale) =
            _prices(m, p.collateralToken, false, submittedAt);
        uint256 mark = p.isLong ? ip.minPrice : ip.maxPrice;
        PriceImpactModel.Quote memory q = PriceImpactModel.quote(
            m.priceImpact,
            mark,
            m.longOiUsd,
            m.shortOiUsd,
            m.config.maxOiUsd,
            sizeDelta,
            p.isLong,
            false
        );
        _slippage(q.executionPrice, acceptable, !p.isLong);
        uint256 oldSize = p.sizeUsd;
        uint256 tokensClosed =
            sizeDelta == oldSize ? p.sizeTokens : MathX.mulDiv(p.sizeTokens, sizeDelta, oldSize);
        int256 rawPnl = _pnl(tokensClosed, sizeDelta, q.executionPrice, p.isLong);
        int256 funding = _fundingPayment(p, _book(m, p.isLong).accFundingRate, oldSize);
        _book(m, p.isLong).unrealisedFundingUsd -= funding;
        MarketPoolToken pool = _vault(m);
        address token = p.collateralToken;
        bool closed = sizeDelta == oldSize;
        uint256 reservingTokens = _reservingFeeTokens(p, vault.accReservingRate);
        uint256 feeTokens =
            _toTokenUp(MathX.mulDivUp(sizeDelta, m.config.tradeFeeWad, WAD), cp.minPrice, scale);
        uint256 fundingPay = funding > 0 ? _toToken(uint256(funding), cp.minPrice, scale) : 0;
        uint256 charges = reservingTokens + feeTokens + fundingPay;
        if (charges > p.collateralAmount) {
            closed = true;
            uint256 room = p.collateralAmount;
            feeTokens = MathX.min(feeTokens, room);
            room -= feeTokens;
            reservingTokens = MathX.min(reservingTokens, room);
            room -= reservingTokens;
            fundingPay = MathX.min(fundingPay, room);
        }
        p.collateralAmount -= feeTokens + reservingTokens + fundingPay;
        vault.liquidity += reservingTokens + fundingPay;
        vault.liquidity += _routeFee(pool, token, feeTokens, keeper);
        _applyReservingCharge(vault, reservingTokens);
        uint256 profitTokens;
        uint256 lossTokens;
        if (rawPnl > 0) {
            profitTokens = _toToken(uint256(rawPnl), cp.maxPrice, scale);
            if (profitTokens >= p.reservedAmount) {
                closed = true;
                profitTokens = p.reservedAmount;
            }
        } else if (rawPnl < 0) {
            lossTokens = _toTokenUp(uint256(-rawPnl), cp.minPrice, scale);
            if (lossTokens >= p.collateralAmount) {
                closed = true;
                lossTokens = p.collateralAmount;
            }
        }
        if (funding < 0) {
            uint256 credit = _toToken(uint256(-funding), cp.maxPrice, scale);
            if (credit > vault.liquidity) credit = vault.liquidity;
            vault.liquidity -= credit;
            p.collateralAmount += credit;
        }
        _subSize(m, p.isLong, tokensClosed);
        m.longOiUsd = q.longOiAfter;
        m.shortOiUsd = q.shortOiAfter;
        _book(m, p.isLong)
        .realisedPnlUsd += rawPnl > 0
            ? -int256(_toUsd(profitTokens, cp.minPrice, scale))
            : int256(_toUsd(lossTokens, cp.minPrice, scale));
        if (lossTokens != 0) {
            p.collateralAmount -= lossTokens;
            vault.liquidity += lossTokens;
        }
        if (profitTokens != 0) {
            p.reservedAmount -= profitTokens;
            vault.reserved -= profitTokens;
        }
        payout = profitTokens;
        if (rawPnl > 0) {
            payout += _pullWinFund(address(pool), token, uint256(rawPnl), cp.minPrice, scale);
        }
        if (closed) {
            payout += p.collateralAmount;
            vault.reserved -= p.reservedAmount;
            vault.liquidity += p.reservedAmount;
            delete positions[id];
        } else {
            if (p.sizeUsd - sizeDelta < m.config.minPositionSizeUsd) revert InvalidAmount();
            p.sizeUsd -= sizeDelta;
            p.sizeTokens -= tokensClosed;
            p.entryReservingRate = vault.accReservingRate;
            p.entryFundingIndex = _book(m, p.isLong).accFundingRate;
            _requireHealthy(p, m);
        }
        if (payout != 0) pool.transferToken(token, account, payout);
        if (rawPnl < 0) _payLossCut(pool, vault, token, uint256(-rawPnl), cp.maxPrice, scale);
        emit PositionDecreased(id, sizeDelta, payout, q.executionPrice);
    }

    function _settleFees(
        Market storage m,
        TokenVault storage vault,
        Position storage p,
        uint256 price,
        uint256 scale
    ) internal {
        uint256 feeTokens = _reservingFeeTokens(p, vault.accReservingRate);
        if (feeTokens > p.collateralAmount) feeTokens = p.collateralAmount;
        p.collateralAmount -= feeTokens;
        vault.liquidity += feeTokens;
        _applyReservingCharge(vault, feeTokens);
        int256 funding = _fundingPayment(p, _book(m, p.isLong).accFundingRate, p.sizeUsd);
        _book(m, p.isLong).unrealisedFundingUsd -= funding;
        if (funding > 0) {
            uint256 pay = _toToken(uint256(funding), price, scale);
            if (pay > p.collateralAmount) pay = p.collateralAmount;
            p.collateralAmount -= pay;
            vault.liquidity += pay;
        } else if (funding < 0) {
            uint256 credit = _toToken(uint256(-funding), price, scale);
            if (credit > vault.liquidity) credit = vault.liquidity;
            vault.liquidity -= credit;
            p.collateralAmount += credit;
        }
    }

    function _reserveFor(
        Market storage m,
        uint256 size,
        uint256 collateral,
        uint256 price,
        uint256 scale
    ) internal view returns (uint256) {
        uint256 reserveTokens = _toToken(
            MathX.mulDiv(size, m.config.reserveFactorWad, WAD), price, scale
        );
        uint256 cap = collateral * m.maxReservedMultiplier;
        return reserveTokens > cap ? cap : reserveTokens;
    }

    function _equity(
        Position storage p,
        Market storage m,
        uint256 mark,
        uint256 collateralPrice,
        uint256 scale
    ) internal view returns (int256) {
        TokenVault storage vault = tokenVaults[m.poolId][p.collateralToken];
        (uint256 accRate,,) = _projectVault(vault);
        (int256 longRate, int256 shortRate,,,) = _projectFunding(m);
        int256 fundingRate = p.isLong ? longRate : shortRate;
        return int256(_toUsd(p.collateralAmount, collateralPrice, scale))
            + _pnl(p.sizeTokens, p.sizeUsd, mark, p.isLong)
            - int256(_toUsd(_reservingFeeTokens(p, accRate), collateralPrice, scale))
            - _fundingPayment(p, fundingRate, p.sizeUsd);
    }

    function _requireHealthy(Position storage p, Market storage m) internal view {
        PoolAsset storage asset = _asset(m.poolId, p.collateralToken);
        PriceData memory ip = oracle.getPrice(m.assetId, m.config.maxClosePriceAge);
        PriceData memory cp = oracle.getPrice(asset.assetId, m.config.maxClosePriceAge);
        int256 e = _equity(p, m, p.isLong ? ip.minPrice : ip.maxPrice, cp.minPrice, asset.scale);
        uint256 collateralUsd = _toUsd(p.collateralAmount, cp.minPrice, asset.scale);
        if (
            e <= int256(MathX.mulDiv(p.sizeUsd, m.config.maintenanceMarginWad, WAD))
                || p.sizeUsd > MathX.mulDiv(collateralUsd, m.config.maxLeverageWad, WAD)
        ) revert MaxLeverageExceeded();
    }

    function _pnl(uint256 sizeTokens, uint256 sizeUsd, uint256 mark, bool isLong)
        internal
        pure
        returns (int256)
    {
        int256 longPnl = int256(MathX.mulDiv(sizeTokens, mark, WAD)) - int256(sizeUsd);
        return isLong ? longPnl : -longPnl;
    }

    function _fundingPayment(Position storage p, int256 index, uint256 size)
        internal
        view
        returns (int256)
    {
        int256 payment = _signedMul(size, index - p.entryFundingIndex);
        return payment;
    }

    function _reservingFeeTokens(Position storage p, uint256 accRate)
        internal
        view
        returns (uint256)
    {
        if (accRate <= p.entryReservingRate || p.reservedAmount == 0) return 0;
        return MathX.mulDiv(p.reservedAmount, accRate - p.entryReservingRate, WAD);
    }

    function _projectVault(TokenVault storage vault)
        internal
        view
        returns (uint256 accRate, uint256 unrealised, uint256 supplyTokens)
    {
        accRate = vault.accReservingRate;
        unrealised = vault.unrealisedReservingFee;
        uint256 elapsed = block.timestamp - vault.lastReservingTime;
        supplyTokens = vault.liquidity + vault.reserved + unrealised / WAD;
        if (
            elapsed == 0 || vault.reservingMultiplierWad == 0 || vault.reserved == 0
                || supplyTokens == 0
        ) return (accRate, unrealised, supplyTokens);
        uint256 utilization = MathX.mulDiv(vault.reserved, WAD, supplyTokens);
        uint256 delta = MathX.mulDiv(
            MathX.mulDiv(vault.reservingMultiplierWad, utilization, WAD), elapsed, EIGHT_HOURS
        );
        accRate += delta;
        unrealised += vault.reserved * delta;
        supplyTokens = vault.liquidity + vault.reserved + unrealised / WAD;
    }

    function _accrueVault(TokenVault storage vault) internal {
        (uint256 accRate, uint256 unrealised,) = _projectVault(vault);
        vault.accReservingRate = accRate;
        vault.unrealisedReservingFee = unrealised;
        vault.lastReservingTime = uint64(block.timestamp);
    }

    function _applyReservingCharge(TokenVault storage vault, uint256 feeTokens) internal {
        uint256 feeWad = feeTokens * WAD;
        if (feeWad > vault.unrealisedReservingFee) feeWad = vault.unrealisedReservingFee;
        vault.unrealisedReservingFee -= feeWad;
    }

    function _projectFunding(Market storage m)
        internal
        view
        returns (
            int256 longRate,
            int256 shortRate,
            int256 longDelta,
            int256 longFee,
            int256 shortFee
        )
    {
        longRate = m.longBook.accFundingRate;
        shortRate = m.shortBook.accFundingRate;
        longFee = m.longBook.unrealisedFundingUsd;
        shortFee = m.shortBook.unrealisedFundingUsd;
        uint256 elapsed = block.timestamp - m.longBook.lastUpdate;
        if (elapsed == 0 || m.fundingMode == 0 || m.fundingMultiplierWad == 0) {
            return (longRate, shortRate, 0, longFee, shortFee);
        }
        int256 signed;
        if (m.fundingMode == 1) {
            signed = _oiRate(m);
        } else {
            signed = _lpPnlRate(m, true);
        }
        longDelta = signed * int256(elapsed) / int256(EIGHT_HOURS);
        int256 shortDelta = m.fundingMode == 1
            ? -longDelta
            : _lpPnlRate(m, false) * int256(elapsed) / int256(EIGHT_HOURS);
        longRate += longDelta;
        shortRate += shortDelta;
        longFee += _signedMul(m.longOiUsd, longDelta);
        shortFee += _signedMul(m.shortOiUsd, shortDelta);
    }

    function _oiRate(Market storage m) internal view returns (int256) {
        uint256 maxLong = m.config.maxOiUsd;
        uint256 maxShort = m.config.maxOiUsd;
        if (maxLong == 0 || maxShort == 0) return 0;
        uint256 normLong = MathX.min(MathX.mulDiv(m.longOiUsd, WAD, maxLong), WAD);
        uint256 normShort = MathX.min(MathX.mulDiv(m.shortOiUsd, WAD, maxShort), WAD);
        if (normLong == normShort) return 0;
        uint256 skew = normLong > normShort ? normLong - normShort : normShort - normLong;
        uint256 powered = _powWad(skew, m.fundingExponent);
        uint256 rate = MathX.mulDiv(m.fundingMultiplierWad, powered, WAD);
        if (rate > m.fundingMaxRateWad) rate = m.fundingMaxRateWad;
        return normLong > normShort ? int256(rate) : -int256(rate);
    }

    function _lpPnlRate(Market storage m, bool isLong) internal view returns (int256) {
        uint256 supply = MarketPoolToken(pools[m.poolId].vault).totalSupply();
        if (supply == 0) return 0;
        uint32 age = m.config.maxClosePriceAge;
        PriceData memory ip = oracle.getPrice(m.assetId, age);
        int256 openPnl = isLong
            ? int256(m.longOiUsd) - int256(MathX.mulDiv(m.longSizeTokens, ip.maxPrice, WAD))
            : int256(MathX.mulDiv(m.shortSizeTokens, ip.minPrice, WAD)) - int256(m.shortOiUsd);
        SideBook storage book = _book(m, isLong);
        int256 pnl = book.realisedPnlUsd + book.unrealisedFundingUsd + openPnl;
        if (pnl == 0) return 0;
        uint256 perLp = MathX.abs(pnl) * WAD / supply;
        uint256 rate = MathX.mulDiv(m.fundingMultiplierWad, perLp, WAD);
        if (rate > m.fundingMaxRateWad) rate = m.fundingMaxRateWad;
        return pnl > 0 ? -int256(rate) : int256(rate);
    }

    function _accrueFunding(Market storage m) internal {
        (int256 longRate, int256 shortRate,, int256 longFee, int256 shortFee) = _projectFunding(m);
        m.longBook.accFundingRate = longRate;
        m.shortBook.accFundingRate = shortRate;
        m.longBook.unrealisedFundingUsd = longFee;
        m.shortBook.unrealisedFundingUsd = shortFee;
        m.longBook.lastUpdate = uint64(block.timestamp);
        m.shortBook.lastUpdate = uint64(block.timestamp);
    }

    function _accruePool(uint32 poolId) internal {
        Pool storage pool = pools[poolId];
        for (uint8 i; i < pool.assetCount; ++i) {
            _accrueVault(tokenVaults[poolId][poolAssets[poolId][i].token]);
        }
        uint256 count = poolMarketIds[poolId].length;
        for (uint256 i; i < count; ++i) {
            _accrueFunding(markets[poolMarketIds[poolId][i]]);
        }
    }

    function _poolVaultsUsd(uint32 poolId) internal view returns (uint256 total) {
        Pool storage pool = pools[poolId];
        for (uint8 i; i < pool.assetCount; ++i) {
            PoolAsset storage asset = poolAssets[poolId][i];
            PriceData memory price = oracle.getPrice(asset.assetId, pool.maxPriceAge);
            total += _vaultValue(poolId, asset.token, price.minPrice);
        }
    }

    function _vaultValue(uint32 poolId, address token, uint256 price)
        internal
        view
        returns (uint256)
    {
        TokenVault storage vault = tokenVaults[poolId][token];
        (, uint256 unrealised, uint256 supplyTokens) = _projectVault(vault);
        PoolAsset storage asset = _asset(poolId, token);
        return _toUsd(supplyTokens, price, asset.scale)
            + MathX.mulDiv(unrealised % WAD, price, asset.scale * WAD);
    }

    function _rebaseFeeUsd(
        bool adding,
        uint256 vaultUsd,
        uint256 totalUsd,
        uint256 amountUsd,
        uint16 weightBps
    ) internal view returns (uint256) {
        if (amountUsd == 0 || totalUsd == 0 || rebaseBaseWad == 0 && rebaseMultiplierWad == 0) {
            return 0;
        }
        uint256 nextVault =
            adding ? vaultUsd + amountUsd : (vaultUsd > amountUsd ? vaultUsd - amountUsd : 0);
        uint256 nextTotal =
            adding ? totalUsd + amountUsd : (totalUsd > amountUsd ? totalUsd - amountUsd : 0);
        if (nextTotal == 0 || nextVault == nextTotal) return 0;
        uint256 ratio = MathX.mulDiv(nextVault, WAD, nextTotal);
        uint256 target = MathX.mulDiv(weightBps, WAD, BPS);
        bool toward = adding ? ratio <= target : ratio >= target;
        uint256 rate = rebaseBaseWad;
        if (!toward) {
            uint256 deviation = ratio > target ? ratio - target : target - ratio;
            rate += MathX.mulDiv(rebaseMultiplierWad, _powWad(deviation, rebaseExponent), WAD);
        }
        return MathX.mulDiv(amountUsd, rate, WAD);
    }

    function _powWad(uint256 base, uint8 exponent) internal pure returns (uint256) {
        uint256 result = base;
        for (uint8 i = 1; i < exponent; ++i) {
            result = MathX.mulDiv(result, base, WAD);
        }
        return result;
    }

    function _pullWinFund(
        address vault,
        address token,
        uint256 profitUsd,
        uint256 price,
        uint256 scale
    ) internal returns (uint256 pulled) {
        if (lossProtection == address(0) || winFundBps == 0 || profitUsd == 0) {
            return 0;
        }
        uint256 want = _toToken(MathX.mulDiv(profitUsd, winFundBps, BPS), price, scale);
        uint256 balance = IERC20(token).balanceOf(lossProtection);
        uint256 allowed = _allowance(token, lossProtection, address(this));
        pulled = want;
        if (pulled > balance) pulled = balance;
        if (pulled > allowed) pulled = allowed;
        if (pulled == 0) return 0;
        token.safeTransferFrom(lossProtection, vault, pulled);
    }

    function _payLossCut(
        MarketPoolToken pool,
        TokenVault storage vault,
        address token,
        uint256 lossUsd,
        uint256 price,
        uint256 scale
    ) internal {
        if (lossProtection == address(0) || lossCutBps == 0 || lossUsd == 0) return;
        uint256 cut = _toToken(MathX.mulDiv(lossUsd, lossCutBps, BPS), price, scale);
        if (cut > vault.liquidity) cut = vault.liquidity;
        if (cut == 0) return;
        vault.liquidity -= cut;
        pool.transferToken(token, lossProtection, cut);
    }

    function _routeFee(MarketPoolToken pool, address token, uint256 amount, address keeper)
        internal
        returns (uint256 lpShare)
    {
        if (amount == 0) return 0;
        FeeConfig memory f = feeConfig;
        uint256 t = MathX.mulDiv(amount, f.treasuryBps, BPS);
        uint256 i = MathX.mulDiv(amount, f.insuranceBps, BPS);
        uint256 k = MathX.mulDiv(amount, f.keeperBps, BPS);
        if (t != 0) pool.transferToken(token, treasury, t);
        if (i != 0) pool.transferToken(token, insuranceFund, i);
        if (k != 0) {
            pool.transferToken(token, keeper == address(0) ? keeperFeeReceiver : keeper, k);
        }
        lpShare = amount - t - i - k;
    }

    function _allowance(address token, address owner_, address spender)
        internal
        view
        returns (uint256)
    {
        (bool ok, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(0xdd62ed3e, owner_, spender));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _signedMul(uint256 size, int256 index) internal pure returns (int256) {
        if (size == 0 || index == 0) return 0;
        if (index > 0) return int256(MathX.mulDiv(size, uint256(index), WAD));
        return -int256(MathX.mulDiv(size, uint256(-index), WAD));
    }

    function _toUsd(uint256 amount, uint256 price, uint256 scale) internal pure returns (uint256) {
        return MathX.mulDiv(amount, price, scale);
    }

    function _toToken(uint256 amount, uint256 price, uint256 scale)
        internal
        pure
        returns (uint256)
    {
        if (price == 0) return 0;
        return MathX.mulDiv(amount, scale, price);
    }

    function _toTokenUp(uint256 amount, uint256 price, uint256 scale)
        internal
        pure
        returns (uint256)
    {
        if (price == 0) return 0;
        return MathX.mulDivUp(amount, scale, price);
    }

    function _prices(Market storage m, address token, bool opening, uint256 submittedAt)
        internal
        returns (PriceData memory ip, PriceData memory cp, uint256 scale)
    {
        PoolAsset storage asset = _asset(m.poolId, token);
        uint32 age = opening ? m.config.maxOpenPriceAge : m.config.maxClosePriceAge;
        ip = oracle.getPriceForAction(m.assetId, age, submittedAt);
        cp = oracle.getPriceForAction(asset.assetId, age, submittedAt);
        scale = asset.scale;
        if (!ip.marketOpen) revert MarketClosed();
    }

    function _slippage(uint256 price, uint256 acceptable, bool buy) internal pure {
        if (acceptable == 0 || (buy ? price > acceptable : price < acceptable)) {
            revert SlippageExceeded();
        }
    }

    function _liquidityPool(uint32 poolId) internal view returns (Pool storage pool) {
        pool = pools[poolId];
        if (pool.assetCount == 0) revert PoolNotFound();
    }

    function _market(uint32 id) internal view returns (Market storage m) {
        m = markets[id];
        if (m.poolId == 0) revert MarketNotFound();
    }

    function _asset(uint32 poolId, address token) internal view returns (PoolAsset storage asset) {
        uint8 index = poolAssetIndex[poolId][token];
        if (index == 0) revert UnsupportedCollateral();
        asset = poolAssets[poolId][index - 1];
    }

    function _tokenVault(uint32 poolId, address token)
        internal
        view
        returns (TokenVault storage vault)
    {
        _asset(poolId, token);
        vault = tokenVaults[poolId][token];
    }

    function _vault(Market storage m) internal view returns (MarketPoolToken) {
        return MarketPoolToken(pools[m.poolId].vault);
    }

    function _book(Market storage m, bool isLong) internal view returns (SideBook storage) {
        if (isLong) return m.longBook;
        return m.shortBook;
    }

    function _owned(uint256 id, address account) internal view returns (Position storage p) {
        p = positions[id];
        if (p.owner == address(0)) revert PositionNotFound();
        if (p.owner != account) revert NotPositionOwner();
    }

    function _addSize(Market storage m, bool isLong, uint256 tokens) internal {
        if (isLong) m.longSizeTokens += tokens;
        else m.shortSizeTokens += tokens;
    }

    function _subSize(Market storage m, bool isLong, uint256 tokens) internal {
        if (isLong) m.longSizeTokens -= tokens;
        else m.shortSizeTokens -= tokens;
    }

    function _checkFn(uint8 id) internal view {
        if (functionMask & (uint256(1) << id) == 0) revert FunctionDisabled(id);
    }

    function _validateConfig(bytes32 assetId, MarketConfig calldata c) internal pure {
        if (
            assetId == 0 || c.maxOiUsd == 0 || c.minPositionSizeUsd == 0 || c.maxLeverageWad < WAD
                || c.maxLeverageWad > 100e18 || c.maxOpenPriceAge == 0 || c.maxClosePriceAge == 0
                || c.maxLiquidationPriceAge == 0 || c.maintenanceMarginWad == 0
                || c.maintenanceMarginWad > 0.5e18 || c.tradeFeeWad > 0.05e18
                || c.liquidationFeeWad > 0.1e18 || c.borrowingFactorPerSecondWad > 0.001e18
                || c.reserveFactorWad > WAD
        ) revert InvalidConfig();
    }
}
