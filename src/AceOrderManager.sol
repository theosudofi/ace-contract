// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable2Step } from "./access/Ownable2Step.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { PriceData } from "./interfaces/IPriceAdapter.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { AcePerp } from "./AcePerp.sol";
import { OracleRouter } from "./oracles/OracleRouter.sol";

/// @notice Escrows conditional orders, collateral and native keeper execution fees.
contract AceOrderManager is Ownable2Step {
    using SafeTransferLib for address;
    enum OrderType {
        LimitIncrease,
        LimitDecrease,
        StopLoss,
        TakeProfit,
        MarketIncrease,
        MarketDecrease
    }

    struct Order {
        address owner;
        OrderType orderType;
        uint32 marketId;
        uint256 positionId;
        bool isLong;
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDeltaUsd;
        uint256 triggerPrice;
        uint256 acceptablePrice;
        uint64 submittedAt;
        uint64 expiresAt;
        uint128 executionFee;
    }

    struct OracleUpdate {
        bytes32 assetId;
        bool secondary;
        bytes data;
        uint256 value;
    }
    error InvalidOrder();
    error UnauthorizedCaller();
    error NotTriggered();
    error OrderExpired();
    error InvalidUpdateValue();
    error TransferFailed();
    error Reentrancy();
    AcePerp public immutable core;
    OracleRouter public immutable oracleRouter;
    uint256 public minExecutionFee;
    uint256 public nextOrderId = 1;
    uint256 private entered = 1;
    mapping(uint256 => Order) public orders;
    address[] public keepers;
    mapping(address => uint256) private keeperIndex;
    event OrderCreated(
        uint256 indexed id, address indexed owner, OrderType orderType, uint64 expiresAt
    );
    event OrderCancelled(uint256 indexed id);
    event OrderExecuted(uint256 indexed id, address indexed keeper, uint256 positionId);

    constructor(address initialOwner, address core_, uint256 minFee) Ownable2Step(initialOwner) {
        if (core_.code.length == 0) revert InvalidOrder();
        core = AcePerp(core_);
        oracleRouter = core.oracleRouter();
        minExecutionFee = minFee;
    }
    modifier nonReentrant() {
        if (entered != 1) revert Reentrancy();
        entered = 2;
        _;
        entered = 1;
    }

    function setMinExecutionFee(uint256 value) external onlyOwner {
        minExecutionFee = value;
    }

    function addKeeper(address keeper) external onlyOwner {
        if (keeper == address(0) || keeperIndex[keeper] != 0) revert InvalidOrder();
        keepers.push(keeper);
        keeperIndex[keeper] = keepers.length;
    }

    function removeKeeper(address keeper) external onlyOwner {
        uint256 index = keeperIndex[keeper];
        if (index == 0) revert InvalidOrder();
        uint256 last = keepers.length;
        if (index != last) {
            address moved = keepers[last - 1];
            keepers[index - 1] = moved;
            keeperIndex[moved] = index;
        }
        keepers.pop();
        delete keeperIndex[keeper];
    }

    function clearKeepers() external onlyOwner {
        uint256 count = keepers.length;
        for (uint256 i; i < count; ++i) {
            delete keeperIndex[keepers[i]];
        }
        delete keepers;
    }

    function keeperCount() external view returns (uint256) {
        return keepers.length;
    }

    /// @notice Creates a market order to open. A keeper executes it.
    function openPosition(
        uint32 marketId,
        address collateralToken,
        uint256 collateral,
        uint256 sizeUsd,
        bool isLong,
        uint256 acceptable,
        uint64 expiresAt
    ) external payable nonReentrant returns (uint256 id) {
        (bytes32 assetId, uint32 maxAge) = core.getMarketOracleConfig(marketId, true);
        PriceData memory price = oracleRouter.getPrice(assetId, maxAge);
        id = _create(
            msg.sender,
            OrderType.MarketIncrease,
            marketId,
            0,
            isLong,
            collateralToken,
            collateral,
            sizeUsd,
            isLong ? price.maxPrice : price.minPrice,
            acceptable,
            expiresAt
        );
    }

    /// @notice Creates a market order to decrease. A keeper executes it.
    function decreasePosition(
        uint256 positionId,
        uint256 sizeDelta,
        uint256 acceptable,
        uint64 expiresAt
    ) external payable nonReentrant returns (uint256 id) {
        (address positionOwner, uint32 marketId, bool isLong,,,,,,,,) = core.positions(positionId);
        if (positionOwner != msg.sender) revert UnauthorizedCaller();
        (bytes32 assetId, uint32 maxAge) = core.getMarketOracleConfig(marketId, false);
        PriceData memory price = oracleRouter.getPrice(assetId, maxAge);
        id = _create(
            msg.sender,
            OrderType.MarketDecrease,
            marketId,
            positionId,
            isLong,
            address(0),
            0,
            sizeDelta,
            isLong ? price.minPrice : price.maxPrice,
            acceptable,
            expiresAt
        );
    }

    function createOrder(
        OrderType orderType,
        uint32 marketId,
        uint256 positionId,
        bool isLong,
        address collateralToken,
        uint256 collateralDelta,
        uint256 sizeDeltaUsd,
        uint256 triggerPrice,
        uint256 acceptablePrice,
        uint64 expiresAt
    ) external payable nonReentrant returns (uint256 id) {
        id = _create(
            msg.sender,
            orderType,
            marketId,
            positionId,
            isLong,
            collateralToken,
            collateralDelta,
            sizeDeltaUsd,
            triggerPrice,
            acceptablePrice,
            expiresAt
        );
    }

    function cancelOrder(uint256 id) external nonReentrant {
        Order memory o = orders[id];
        if (o.owner == address(0)) revert InvalidOrder();
        if (msg.sender != o.owner) revert UnauthorizedCaller();
        delete orders[id];
        _refund(o, o.owner);
        emit OrderCancelled(id);
    }

    function cancelExpired(uint256 id) external nonReentrant {
        Order memory o = orders[id];
        if (o.owner == address(0)) revert InvalidOrder();
        if (block.timestamp <= o.expiresAt) revert InvalidOrder();
        delete orders[id];
        if (o.collateralDelta != 0) {
            o.collateralToken.safeTransfer(o.owner, o.collateralDelta);
        }
        _sendNative(msg.sender, o.executionFee);
        emit OrderCancelled(id);
    }

    function executeOrder(uint256 id, OracleUpdate[] calldata updates)
        external
        payable
        nonReentrant
        returns (uint256 positionId)
    {
        _authorizedKeeper();
        Order memory o = orders[id];
        if (o.owner == address(0)) revert InvalidOrder();
        if (block.timestamp > o.expiresAt) revert OrderExpired();
        uint256 total;
        for (uint256 i; i < updates.length; ++i) {
            total += updates[i].value;
            oracleRouter.updatePrice{ value: updates[i].value }(
                updates[i].assetId, updates[i].secondary, updates[i].data
            );
        }
        if (total != msg.value) revert InvalidUpdateValue();
        bool increase =
            o.orderType == OrderType.LimitIncrease || o.orderType == OrderType.MarketIncrease;
        (bytes32 assetId, uint32 maxAge) = core.getMarketOracleConfig(o.marketId, increase);
        PriceData memory price = oracleRouter.getPrice(assetId, maxAge);
        if (price.updatedAt < o.submittedAt) revert InvalidOrder();
        if (!_triggered(o, price)) revert NotTriggered();
        delete orders[id];
        if (increase) {
            if (o.collateralDelta != 0) {
                IERC20(o.collateralToken).approve(address(core), 0);
                IERC20(o.collateralToken).approve(address(core), o.collateralDelta);
            }
            positionId = core.executeOrderIncrease(
                o.owner,
                o.marketId,
                o.positionId,
                o.collateralToken,
                o.collateralDelta,
                o.sizeDeltaUsd,
                o.isLong,
                o.acceptablePrice,
                o.submittedAt,
                msg.sender
            );
        } else {
            positionId = o.positionId;
            core.executeOrderDecrease(
                o.owner, o.positionId, o.sizeDeltaUsd, o.acceptablePrice, o.submittedAt, msg.sender
            );
            if (o.collateralDelta != 0) {
                o.collateralToken.safeTransfer(o.owner, o.collateralDelta);
            }
        }
        _sendNative(msg.sender, o.executionFee);
        emit OrderExecuted(id, msg.sender, positionId);
    }

    function _create(
        address account,
        OrderType orderType,
        uint32 marketId,
        uint256 positionId,
        bool isLong,
        address collateralToken,
        uint256 collateralDelta,
        uint256 sizeDeltaUsd,
        uint256 triggerPrice,
        uint256 acceptablePrice,
        uint64 expiresAt
    ) private returns (uint256 id) {
        bool increase = orderType == OrderType.LimitIncrease
            || orderType == OrderType.MarketIncrease;
        if (
            msg.value < minExecutionFee || sizeDeltaUsd == 0 || triggerPrice == 0
                || msg.value > type(uint128).max || acceptablePrice == 0
                || expiresAt <= block.timestamp
                || (increase ? positionId != 0 && collateralDelta == 0 : positionId == 0)
        ) revert InvalidOrder();
        if (collateralDelta != 0 && collateralToken == address(0)) revert InvalidOrder();
        if (positionId != 0) {
            (
                address positionOwner,
                uint32 positionMarket,
                bool positionIsLong,
                address positionCollateral,,,,,,,
            ) = core.positions(positionId);
            if (
                positionOwner != account || positionMarket != marketId || positionIsLong != isLong
                    || (collateralDelta != 0 && positionCollateral != collateralToken)
            ) revert InvalidOrder();
        }
        if (collateralDelta != 0) {
            collateralToken.safeTransferFrom(account, address(this), collateralDelta);
        }
        id = nextOrderId++;
        orders[id] = Order(
            account,
            orderType,
            marketId,
            positionId,
            isLong,
            collateralToken,
            collateralDelta,
            sizeDeltaUsd,
            triggerPrice,
            acceptablePrice,
            uint64(block.timestamp),
            expiresAt,
            uint128(msg.value)
        );
        emit OrderCreated(id, account, orderType, expiresAt);
    }

    function _authorizedKeeper() private view {
        if (keepers.length != 0 && keeperIndex[msg.sender] == 0) revert UnauthorizedCaller();
    }

    function _triggered(Order memory o, PriceData memory p) private pure returns (bool) {
        if (o.orderType == OrderType.MarketIncrease) {
            return o.isLong ? p.maxPrice <= o.acceptablePrice : p.minPrice >= o.acceptablePrice;
        }
        if (o.orderType == OrderType.MarketDecrease) {
            return o.isLong ? p.minPrice >= o.acceptablePrice : p.maxPrice <= o.acceptablePrice;
        }
        if (o.orderType == OrderType.LimitIncrease) {
            return o.isLong ? p.maxPrice <= o.triggerPrice : p.minPrice >= o.triggerPrice;
        }
        if (o.orderType == OrderType.StopLoss) {
            return o.isLong ? p.minPrice <= o.triggerPrice : p.maxPrice >= o.triggerPrice;
        }
        return o.isLong ? p.minPrice >= o.triggerPrice : p.maxPrice <= o.triggerPrice;
    }

    function _refund(Order memory o, address recipient) private {
        if (o.collateralDelta != 0) {
            o.collateralToken.safeTransfer(recipient, o.collateralDelta);
        }
        _sendNative(recipient, o.executionFee);
    }

    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }
}
