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

/// @notice Isolated-market perpetuals core. Every market side has independent custody and LP shares.
contract AcePerp is Ownable2Step {
    using SafeTransferLib for address;
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

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

    struct SideAccounting {
        uint256 sizeTokens;
        uint256 collateralTokens;
        uint256 cumulativeBorrowingIndex;
        uint256 borrowingBaselineUsd;
        uint64 lastBorrowingTime;
    }

    struct Market {
        bytes32 assetId;
        bool enabled;
        MarketConfig config;
        PriceImpactModel.Config priceImpact;
        address longPool;
        address shortPool;
        uint256 longOiUsd;
        uint256 shortOiUsd;
        SideAccounting longSide;
        SideAccounting shortSide;
    }

    struct Position {
        address owner;
        uint32 marketId;
        bool isLong;
        uint256 collateralAmount;
        uint256 sizeUsd;
        uint256 sizeTokens;
        uint256 entryPrice;
        uint256 entryBorrowingIndex;
    }

    struct FeeConfig {
        uint16 treasuryBps;
        uint16 insuranceBps;
        uint16 keeperBps;
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
    error UnauthorizedCaller();
    error MarketClosed();

    IERC20 public immutable collateralToken;
    uint8 public immutable collateralDecimals;
    uint256 public immutable collateralScale;
    bytes32 public immutable collateralAssetId;
    OracleRouter public immutable oracleRouter;
    MarketPoolFactory public immutable poolFactory;
    address public guardian;
    address public orderManager;
    address public treasury;
    address public insuranceFund;
    address public keeperFeeReceiver;
    bool public paused;
    FeeConfig public feeConfig;
    uint32 public marketCount;
    uint256 public nextPositionId = 1;
    uint256 private entered = 1;
    mapping(uint32 => Market) public markets;
    mapping(uint256 => Position) public positions;

    event MarketCreated(
        uint32 indexed marketId, bytes32 indexed assetId, address longPool, address shortPool
    );
    event LiquidityDeposited(
        address indexed provider,
        uint32 indexed marketId,
        bool indexed isLong,
        uint256 assets,
        uint256 shares
    );
    event LiquidityWithdrawn(
        address indexed provider,
        uint32 indexed marketId,
        bool indexed isLong,
        uint256 assets,
        uint256 shares
    );
    event PositionOpened(
        uint256 indexed id,
        address indexed owner,
        uint32 indexed marketId,
        bool isLong,
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

    constructor(
        address initialOwner,
        address guardian_,
        address token_,
        bytes32 collateralId_,
        address router_
    ) Ownable2Step(initialOwner) {
        if (
            guardian_ == address(0) || token_.code.length == 0 || router_.code.length == 0
                || collateralId_ == 0
        ) revert InvalidConfig();
        uint8 d = IERC20(token_).decimals();
        if (d > 18) revert InvalidConfig();
        guardian = guardian_;
        collateralToken = IERC20(token_);
        collateralDecimals = d;
        collateralScale = 10 ** d;
        collateralAssetId = collateralId_;
        oracleRouter = OracleRouter(router_);
        treasury = initialOwner;
        poolFactory = new MarketPoolFactory();
        insuranceFund = initialOwner;
        keeperFeeReceiver = initialOwner;
        feeConfig = FeeConfig(1500, 1000, 500);
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

    function createMarket(
        bytes32 assetId,
        MarketConfig calldata config,
        PriceImpactModel.Config calldata impact
    ) external onlyOwner returns (uint32 id) {
        _validateConfig(assetId, config);
        PriceImpactModel.validate(impact);
        id = ++marketCount;
        Market storage m = markets[id];
        m.assetId = assetId;
        m.enabled = true;
        m.config = config;
        m.priceImpact = impact;
        m.longPool = poolFactory.create(address(collateralToken), address(this), true);
        m.shortPool = poolFactory.create(address(collateralToken), address(this), false);
        m.longSide.lastBorrowingTime = uint64(block.timestamp);
        m.shortSide.lastBorrowingTime = uint64(block.timestamp);
        emit MarketCreated(id, assetId, m.longPool, m.shortPool);
    }

    function setMarketConfig(uint32 id, MarketConfig calldata config) external onlyOwner {
        Market storage m = _market(id);
        _validateConfig(m.assetId, config);
        _updateBorrowing(m, true);
        _updateBorrowing(m, false);
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

    function depositLiquidity(uint32 id, bool isLong, uint256 amount, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (amount == 0) revert InvalidAmount();
        Market storage m = _market(id);
        _updateBorrowing(m, isLong);
        MarketPoolToken pool = _pool(m, isLong);
        uint256 supply = pool.totalSupply();
        uint256 nav = marketPoolNavUsd(id, isLong);
        PriceData memory cp = oracleRouter.getPrice(collateralAssetId, m.config.maxClosePriceAge);
        uint256 usd = _tokenToUsd(amount, cp.minPrice);
        shares = supply == 0 ? usd : MathX.mulDiv(usd, supply, nav);
        if (shares == 0 || shares < minShares) revert SlippageExceeded();
        address(collateralToken).safeTransferFrom(msg.sender, address(pool), amount);
        pool.mint(msg.sender, shares);
        emit LiquidityDeposited(msg.sender, id, isLong, amount, shares);
    }

    function withdrawLiquidity(uint32 id, bool isLong, uint256 shares, uint256 minAmount)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (shares == 0) revert InvalidAmount();
        Market storage m = _market(id);
        _updateBorrowing(m, isLong);
        MarketPoolToken pool = _pool(m, isLong);
        uint256 supply = pool.totalSupply();
        if (shares > pool.balanceOf(msg.sender)) revert InvalidAmount();
        uint256 nav = marketPoolNavUsd(id, isLong);
        PriceData memory cp = oracleRouter.getPrice(collateralAssetId, m.config.maxClosePriceAge);
        amount = _usdToToken(MathX.mulDiv(nav, shares, supply), cp.maxPrice);
        if (amount < minAmount) revert SlippageExceeded();
        SideAccounting storage s = _side(m, isLong);
        uint256 free = collateralToken.balanceOf(address(pool)) - s.collateralTokens;
        if (amount > free) revert InsufficientLiquidity();
        pool.burn(msg.sender, shares);
        pool.transferAsset(msg.sender, amount);
        _checkReserve(m, isLong, cp.minPrice);
        emit LiquidityWithdrawn(msg.sender, id, isLong, amount, shares);
    }

    function openPosition(
        uint32 id,
        uint256 collateral,
        uint256 sizeUsd,
        bool isLong,
        uint256 acceptable
    ) external nonReentrant returns (uint256) {
        return _open(msg.sender, msg.sender, id, collateral, sizeUsd, isLong, acceptable, 0);
    }

    function increasePosition(
        uint256 id,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 acceptable
    ) external nonReentrant {
        Position storage p = _owned(id, msg.sender);
        _increase(p, id, msg.sender, collateralDelta, sizeDelta, acceptable, 0);
    }

    function addCollateral(uint256 id, uint256 amount) external nonReentrant {
        Position storage p = _owned(id, msg.sender);
        if (amount == 0) revert InvalidAmount();
        Market storage m = markets[p.marketId];
        MarketPoolToken pool = _pool(m, p.isLong);
        address(collateralToken).safeTransferFrom(msg.sender, address(pool), amount);
        p.collateralAmount += amount;
        _side(m, p.isLong).collateralTokens += amount;
        emit CollateralChanged(id, int256(amount));
    }

    function withdrawCollateral(uint256 id, uint256 amount) external nonReentrant {
        Position storage p = _owned(id, msg.sender);
        if (amount == 0 || amount >= p.collateralAmount) revert InvalidAmount();
        Market storage m = markets[p.marketId];
        _updateBorrowing(m, p.isLong);
        p.collateralAmount -= amount;
        _side(m, p.isLong).collateralTokens -= amount;
        _requireHealthy(p, m);
        _pool(m, p.isLong).transferAsset(msg.sender, amount);
        emit CollateralChanged(id, -int256(amount));
    }

    function decreasePosition(uint256 id, uint256 sizeDelta, uint256 acceptable)
        external
        nonReentrant
        returns (uint256)
    {
        Position storage p = _owned(id, msg.sender);
        return _decrease(p, id, msg.sender, sizeDelta, acceptable, 0, keeperFeeReceiver);
    }

    function executeOrderIncrease(
        address account,
        uint32 marketId,
        uint256 positionId,
        uint256 collateral,
        uint256 size,
        bool isLong,
        uint256 acceptable,
        uint256 submittedAt,
        address keeper
    ) external nonReentrant returns (uint256 id) {
        if (msg.sender != orderManager) revert UnauthorizedCaller();
        if (positionId == 0) {
            id = _open(
                account, msg.sender, marketId, collateral, size, isLong, acceptable, submittedAt
            );
        } else {
            Position storage p = _owned(positionId, account);
            _increase(p, positionId, msg.sender, collateral, size, acceptable, submittedAt);
            id = positionId;
        }
        keeper; // execution fee is native and paid by the order manager
    }

    function executeOrderDecrease(
        address account,
        uint256 positionId,
        uint256 size,
        uint256 acceptable,
        uint256 submittedAt,
        address keeper
    ) external nonReentrant returns (uint256) {
        if (msg.sender != orderManager) revert UnauthorizedCaller();
        Position storage p = _owned(positionId, account);
        return _decrease(p, positionId, account, size, acceptable, submittedAt, keeper);
    }

    function liquidate(uint256 id) external nonReentrant returns (uint256 reward) {
        Position storage p = positions[id];
        if (p.owner == address(0)) revert PositionNotFound();
        Market storage m = markets[p.marketId];
        _updateBorrowing(m, p.isLong);
        PriceData memory ip =
            oracleRouter.getPriceForAction(m.assetId, m.config.maxLiquidationPriceAge, 0);
        PriceData memory cp =
            oracleRouter.getPriceForAction(collateralAssetId, m.config.maxLiquidationPriceAge, 0);
        uint256 mark = p.isLong ? ip.minPrice : ip.maxPrice;
        int256 equity = _equity(p, mark, cp.minPrice, _side(m, p.isLong).cumulativeBorrowingIndex);
        if (equity > int256(MathX.mulDiv(p.sizeUsd, m.config.maintenanceMarginWad, WAD))) {
            revert PositionHealthy();
        }
        uint256 borrowingUsd =
            _borrowingFee(p, _side(m, p.isLong).cumulativeBorrowingIndex, p.sizeUsd);
        uint256 positive = equity > 0 ? uint256(equity) : 0;
        uint256 rewardUsd =
            MathX.min(positive, MathX.mulDiv(p.sizeUsd, m.config.liquidationFeeWad, WAD));
        reward = _usdToToken(rewardUsd, cp.maxPrice);
        uint256 userPayout = _usdToToken(positive - rewardUsd, cp.maxPrice);
        address account = p.owner;
        bool wasLong = p.isLong;
        uint256 size = p.sizeUsd;
        uint256 positionCollateral = p.collateralAmount;
        MarketPoolToken pool = _pool(m, wasLong);
        _removePositionAccounting(m, p, size, p.sizeTokens, positionCollateral);
        if (wasLong) m.longOiUsd -= size;
        else m.shortOiUsd -= size;
        delete positions[id];
        _routeFee(
            pool,
            MathX.min(_usdToTokenUp(borrowingUsd, cp.minPrice), positionCollateral),
            msg.sender
        );
        if (reward != 0) pool.transferAsset(msg.sender, reward);
        if (userPayout != 0) pool.transferAsset(account, userPayout);
        emit PositionLiquidated(id, msg.sender, reward);
    }

    function marketPoolNavUsd(uint32 id, bool isLong) public view returns (uint256) {
        Market storage m = markets[id];
        if (m.assetId == 0) revert MarketNotFound();
        SideAccounting storage s = _side(m, isLong);
        MarketPoolToken pool = _pool(m, isLong);
        PriceData memory cp = oracleRouter.getPrice(collateralAssetId, m.config.maxClosePriceAge);
        PriceData memory ip = oracleRouter.getPrice(m.assetId, m.config.maxClosePriceAge);
        uint256 assets = _tokenToUsd(collateralToken.balanceOf(address(pool)), cp.minPrice);
        uint256 collateral = _tokenToUsd(s.collateralTokens, cp.maxPrice);
        int256 pnl = _aggregatePnl(m, isLong, isLong ? ip.maxPrice : ip.minPrice);
        uint256 pending = _pendingBorrowing(m, isLong);
        int256 nav = int256(assets) - int256(collateral) - pnl + int256(pending);
        return nav > 0 ? uint256(nav) : 0;
    }

    function marketTokenPrice(uint32 id, bool isLong) external view returns (uint256) {
        MarketPoolToken pool = _pool(markets[id], isLong);
        uint256 supply = pool.totalSupply();
        return supply == 0 ? WAD : MathX.mulDiv(marketPoolNavUsd(id, isLong), WAD, supply);
    }

    function positionEquityUsd(uint256 id) external view returns (int256 equity, uint256 mark) {
        Position storage p = positions[id];
        if (p.owner == address(0)) revert PositionNotFound();
        Market storage m = markets[p.marketId];
        PriceData memory ip = oracleRouter.getPrice(m.assetId, m.config.maxClosePriceAge);
        PriceData memory cp = oracleRouter.getPrice(collateralAssetId, m.config.maxClosePriceAge);
        mark = p.isLong ? ip.minPrice : ip.maxPrice;
        equity = _equity(p, mark, cp.minPrice, _projectBorrowing(m, p.isLong));
    }

    function getMarketOracleConfig(uint32 id, bool opening)
        external
        view
        returns (bytes32 assetId, uint32 maxAge)
    {
        Market storage m = _market(id);
        return (m.assetId, opening ? m.config.maxOpenPriceAge : m.config.maxClosePriceAge);
    }

    function getMarketPools(uint32 id) external view returns (address longPool, address shortPool) {
        Market storage m = _market(id);
        return (m.longPool, m.shortPool);
    }

    function _open(
        address account,
        address payer,
        uint32 id,
        uint256 collateral,
        uint256 size,
        bool isLong,
        uint256 acceptable,
        uint256 submittedAt
    ) private returns (uint256 positionId) {
        if (paused) revert ProtocolPaused();
        Market storage m = _market(id);
        if (!m.enabled) revert MarketDisabled();
        if (collateral == 0 || size < m.config.minPositionSizeUsd) revert InvalidAmount();
        _updateBorrowing(m, isLong);
        (PriceData memory ip, PriceData memory cp) = _prices(m, true, submittedAt);
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
        MarketPoolToken pool = _pool(m, isLong);
        address(collateralToken).safeTransferFrom(payer, address(pool), collateral);
        uint256 fee = _usdToToken(MathX.mulDivUp(size, m.config.tradeFeeWad, WAD), cp.minPrice);
        if (fee >= collateral) revert MaxLeverageExceeded();
        uint256 net = collateral - fee;
        _routeFee(pool, fee, address(0));
        SideAccounting storage s = _side(m, isLong);
        positionId = nextPositionId++;
        uint256 sizeTokens = MathX.mulDiv(size, WAD, q.executionPrice);
        positions[positionId] = Position(
            account, id, isLong, net, size, sizeTokens, q.executionPrice, s.cumulativeBorrowingIndex
        );
        s.collateralTokens += net;
        s.sizeTokens += sizeTokens;
        s.borrowingBaselineUsd += MathX.mulDiv(size, s.cumulativeBorrowingIndex, WAD);
        m.longOiUsd = q.longOiAfter;
        m.shortOiUsd = q.shortOiAfter;
        _requireHealthy(positions[positionId], m);
        _checkReserve(m, isLong, cp.minPrice);
        emit PositionOpened(positionId, account, id, isLong, size, net, q.executionPrice);
    }

    function _increase(
        Position storage p,
        uint256 id,
        address payer,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 acceptable,
        uint256 submittedAt
    ) private {
        if (paused) revert ProtocolPaused();
        if (collateralDelta == 0 && sizeDelta == 0) revert InvalidAmount();
        Market storage m = markets[p.marketId];
        if (!m.enabled) revert MarketDisabled();
        _updateBorrowing(m, p.isLong);
        (PriceData memory ip, PriceData memory cp) = _prices(m, true, submittedAt);
        MarketPoolToken pool = _pool(m, p.isLong);
        SideAccounting storage s = _side(m, p.isLong);
        if (collateralDelta != 0) {
            address(collateralToken).safeTransferFrom(payer, address(pool), collateralDelta);
        }
        uint256 price = p.entryPrice;
        uint256 fee;
        uint256 addedTokens;
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
            m.longOiUsd = q.longOiAfter;
            m.shortOiUsd = q.shortOiAfter;
            price = q.executionPrice;
            fee = _usdToToken(MathX.mulDivUp(sizeDelta, m.config.tradeFeeWad, WAD), cp.minPrice);
            addedTokens = MathX.mulDiv(sizeDelta, WAD, price);
        }
        if (fee >= collateralDelta + p.collateralAmount) revert MaxLeverageExceeded();
        uint256 borrowing =
            _usdToToken(_borrowingFee(p, s.cumulativeBorrowingIndex, p.sizeUsd), cp.minPrice);
        if (borrowing + fee > p.collateralAmount + collateralDelta) revert MaxLeverageExceeded();
        uint256 charge = borrowing + fee;
        p.collateralAmount = p.collateralAmount + collateralDelta - charge;
        s.collateralTokens = s.collateralTokens + collateralDelta - charge;
        _routeFee(pool, charge, p.owner);
        s.borrowingBaselineUsd -= MathX.mulDiv(p.sizeUsd, p.entryBorrowingIndex, WAD);
        p.entryBorrowingIndex = s.cumulativeBorrowingIndex;
        if (sizeDelta != 0) {
            p.sizeUsd += sizeDelta;
            p.sizeTokens += addedTokens;
            p.entryPrice = MathX.mulDiv(p.sizeUsd, WAD, p.sizeTokens);
            s.sizeTokens += addedTokens;
            if (p.isLong) m.longOiUsd = m.longOiUsd;
        }
        s.borrowingBaselineUsd += MathX.mulDiv(p.sizeUsd, p.entryBorrowingIndex, WAD);
        _requireHealthy(p, m);
        _checkReserve(m, p.isLong, cp.minPrice);
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
    ) private returns (uint256 payout) {
        if (sizeDelta == 0 || sizeDelta > p.sizeUsd) revert InvalidAmount();
        Market storage m = markets[p.marketId];
        _updateBorrowing(m, p.isLong);
        (PriceData memory ip, PriceData memory cp) = _prices(m, false, submittedAt);
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
        uint256 released = MathX.mulDiv(p.collateralAmount, sizeDelta, oldSize);
        uint256 tokensClosed =
            sizeDelta == oldSize ? p.sizeTokens : MathX.mulDiv(p.sizeTokens, sizeDelta, oldSize);
        int256 pnl = _pnl(tokensClosed, sizeDelta, q.executionPrice, p.isLong);
        uint256 borrow = MathX.mulDiv(
            _borrowingFee(p, _side(m, p.isLong).cumulativeBorrowingIndex, oldSize),
            sizeDelta,
            oldSize
        );
        uint256 tradeFee = MathX.mulDivUp(sizeDelta, m.config.tradeFeeWad, WAD);
        int256 equityUsd =
            int256(_tokenToUsd(released, cp.minPrice)) + pnl - int256(borrow + tradeFee);
        payout = equityUsd > 0 ? _usdToToken(uint256(equityUsd), cp.maxPrice) : 0;
        MarketPoolToken pool = _pool(m, p.isLong);
        _removePositionAccounting(m, p, sizeDelta, tokensClosed, released);
        m.longOiUsd = q.longOiAfter;
        m.shortOiUsd = q.shortOiAfter;
        uint256 feeToken = _usdToTokenUp(borrow + tradeFee, cp.minPrice);
        _routeFee(pool, MathX.min(feeToken, released), keeper);
        if (payout != 0) pool.transferAsset(account, payout);
        if (p.sizeUsd == 0) {
            delete positions[id];
        } else {
            if (p.sizeUsd < m.config.minPositionSizeUsd) revert InvalidAmount();
            _requireHealthy(p, m);
        }
        emit PositionDecreased(id, sizeDelta, payout, q.executionPrice);
    }

    function _removePositionAccounting(
        Market storage m,
        Position storage p,
        uint256 size,
        uint256 tokens,
        uint256 collateral
    ) private {
        SideAccounting storage s = _side(m, p.isLong);
        s.borrowingBaselineUsd -= MathX.mulDiv(size, p.entryBorrowingIndex, WAD);
        s.sizeTokens -= tokens;
        s.collateralTokens -= collateral;
        p.sizeUsd -= size;
        p.sizeTokens -= tokens;
        p.collateralAmount -= collateral;
    }

    function _prices(Market storage m, bool opening, uint256 submittedAt)
        private
        returns (PriceData memory ip, PriceData memory cp)
    {
        uint256 age = opening ? m.config.maxOpenPriceAge : m.config.maxClosePriceAge;
        ip = oracleRouter.getPriceForAction(m.assetId, age, submittedAt);
        cp = oracleRouter.getPriceForAction(collateralAssetId, age, submittedAt);
        if (!ip.marketOpen) revert MarketClosed();
    }

    function _requireHealthy(Position storage p, Market storage m) private view {
        PriceData memory ip = oracleRouter.getPrice(m.assetId, m.config.maxClosePriceAge);
        PriceData memory cp = oracleRouter.getPrice(collateralAssetId, m.config.maxClosePriceAge);
        int256 e = _equity(
            p,
            p.isLong ? ip.minPrice : ip.maxPrice,
            cp.minPrice,
            _side(m, p.isLong).cumulativeBorrowingIndex
        );
        uint256 collateralUsd = _tokenToUsd(p.collateralAmount, cp.minPrice);
        if (
            e <= int256(MathX.mulDiv(p.sizeUsd, m.config.maintenanceMarginWad, WAD))
                || p.sizeUsd > MathX.mulDiv(collateralUsd, m.config.maxLeverageWad, WAD)
        ) revert MaxLeverageExceeded();
    }

    function _equity(Position storage p, uint256 mark, uint256 collateralPrice, uint256 index)
        private
        view
        returns (int256)
    {
        return int256(_tokenToUsd(p.collateralAmount, collateralPrice))
            + _pnl(p.sizeTokens, p.sizeUsd, mark, p.isLong)
            - int256(_borrowingFee(p, index, p.sizeUsd));
    }

    function _pnl(uint256 sizeTokens, uint256 sizeUsd, uint256 mark, bool isLong)
        private
        pure
        returns (int256)
    {
        int256 longPnl = int256(MathX.mulDiv(sizeTokens, mark, WAD)) - int256(sizeUsd);
        return isLong ? longPnl : -longPnl;
    }

    function _aggregatePnl(Market storage m, bool isLong, uint256 mark)
        private
        view
        returns (int256)
    {
        SideAccounting storage s = _side(m, isLong);
        return _pnl(s.sizeTokens, isLong ? m.longOiUsd : m.shortOiUsd, mark, isLong);
    }

    function _borrowingFee(Position storage p, uint256 index, uint256 size)
        private
        view
        returns (uint256)
    {
        return index <= p.entryBorrowingIndex
            ? 0
            : MathX.mulDiv(size, index - p.entryBorrowingIndex, WAD);
    }

    function _pendingBorrowing(Market storage m, bool isLong) private view returns (uint256) {
        SideAccounting storage s = _side(m, isLong);
        uint256 accrued =
            MathX.mulDiv(isLong ? m.longOiUsd : m.shortOiUsd, _projectBorrowing(m, isLong), WAD);
        uint256 gross = accrued > s.borrowingBaselineUsd ? accrued - s.borrowingBaselineUsd : 0;
        FeeConfig memory f = feeConfig;
        return MathX.mulDiv(gross, BPS - f.treasuryBps - f.insuranceBps - f.keeperBps, BPS);
    }

    function _projectBorrowing(Market storage m, bool isLong) private view returns (uint256) {
        SideAccounting storage s = _side(m, isLong);
        uint256 elapsed = block.timestamp - s.lastBorrowingTime;
        if (elapsed == 0) return s.cumulativeBorrowingIndex;
        uint256 oi = isLong ? m.longOiUsd : m.shortOiUsd;
        uint256 balance = collateralToken.balanceOf(address(_pool(m, isLong)));
        uint256 poolAssets = balance > s.collateralTokens ? balance - s.collateralTokens : 0;
        if (oi == 0 || poolAssets == 0) return s.cumulativeBorrowingIndex;
        PriceData memory cp = oracleRouter.getPrice(collateralAssetId, m.config.maxClosePriceAge);
        uint256 poolUsd = _tokenToUsd(poolAssets, cp.minPrice);
        uint256 utilization = MathX.min(MathX.mulDiv(oi, WAD, poolUsd), WAD);
        return s.cumulativeBorrowingIndex
            + MathX.mulDiv(
            uint256(m.config.borrowingFactorPerSecondWad) * elapsed, utilization, WAD
        );
    }

    function _updateBorrowing(Market storage m, bool isLong) private {
        SideAccounting storage s = _side(m, isLong);
        s.cumulativeBorrowingIndex = _projectBorrowing(m, isLong);
        s.lastBorrowingTime = uint64(block.timestamp);
    }

    function _checkReserve(Market storage m, bool isLong, uint256 collateralPrice) private view {
        SideAccounting storage s = _side(m, isLong);
        uint256 free = collateralToken.balanceOf(address(_pool(m, isLong))) - s.collateralTokens;
        uint256 required =
            MathX.mulDiv(isLong ? m.longOiUsd : m.shortOiUsd, m.config.reserveFactorWad, WAD);
        if (_tokenToUsd(free, collateralPrice) < required) revert ReserveRequirement();
    }

    function _routeFee(MarketPoolToken pool, uint256 amount, address keeper) private {
        if (amount == 0) return;
        FeeConfig memory f = feeConfig;
        uint256 t = MathX.mulDiv(amount, f.treasuryBps, BPS);
        uint256 i = MathX.mulDiv(amount, f.insuranceBps, BPS);
        uint256 k = MathX.mulDiv(amount, f.keeperBps, BPS);
        if (t != 0) pool.transferAsset(treasury, t);
        if (i != 0) pool.transferAsset(insuranceFund, i);
        if (k != 0) pool.transferAsset(keeper == address(0) ? keeperFeeReceiver : keeper, k);
    }

    function _slippage(uint256 price, uint256 acceptable, bool buy) private pure {
        if (acceptable == 0 || (buy ? price > acceptable : price < acceptable)) {
            revert SlippageExceeded();
        }
    }

    function _market(uint32 id) private view returns (Market storage m) {
        m = markets[id];
        if (m.assetId == 0) revert MarketNotFound();
    }

    function _side(Market storage m, bool isLong) private view returns (SideAccounting storage) {
        return isLong ? m.longSide : m.shortSide;
    }

    function _pool(Market storage m, bool isLong) private view returns (MarketPoolToken) {
        return MarketPoolToken(isLong ? m.longPool : m.shortPool);
    }

    function _owned(uint256 id, address account) private view returns (Position storage p) {
        p = positions[id];
        if (p.owner == address(0)) revert PositionNotFound();
        if (p.owner != account) revert NotPositionOwner();
    }

    function _tokenToUsd(uint256 amount, uint256 price) private view returns (uint256) {
        return MathX.mulDiv(amount, price, collateralScale);
    }

    function _usdToToken(uint256 amount, uint256 price) private view returns (uint256) {
        return MathX.mulDiv(amount, collateralScale, price);
    }

    function _usdToTokenUp(uint256 amount, uint256 price) private view returns (uint256) {
        return MathX.mulDivUp(amount, collateralScale, price);
    }

    function _validateConfig(bytes32 assetId, MarketConfig calldata c) private pure {
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
