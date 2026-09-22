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
        TakeProfit
    }

    struct Order {
        address owner;
        OrderType orderType;
        uint32 marketId;
        uint256 positionId;
        bool isLong;
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
    IERC20 public immutable collateralToken;
    AcePerp public immutable core;
    OracleRouter public immutable oracleRouter;
    uint256 public minExecutionFee;
    uint256 public nextOrderId = 1;
    uint256 private entered = 1;
    mapping(uint256 => Order) public orders;
    event OrderCreated(
        uint256 indexed id, address indexed owner, OrderType orderType, uint64 expiresAt
    );
    event OrderCancelled(uint256 indexed id);
    event OrderExecuted(uint256 indexed id, address indexed keeper, uint256 positionId);

    constructor(address initialOwner, address core_, uint256 minFee) Ownable2Step(initialOwner) {
        if (core_.code.length == 0) revert InvalidOrder();
        core = AcePerp(core_);
        collateralToken = core.collateralToken();
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

    function createOrder(
        OrderType orderType,
        uint32 marketId,
        uint256 positionId,
        bool isLong,
        uint256 collateralDelta,
        uint256 sizeDeltaUsd,
        uint256 triggerPrice,
        uint256 acceptablePrice,
        uint64 expiresAt
    ) external payable nonReentrant returns (uint256 id) {
        bool increase = orderType == OrderType.LimitIncrease;
        if (
            msg.value < minExecutionFee || sizeDeltaUsd == 0 || triggerPrice == 0
                || msg.value > type(uint128).max || acceptablePrice == 0
                || expiresAt <= block.timestamp
                || (increase ? positionId != 0 && collateralDelta == 0 : positionId == 0)
        ) revert InvalidOrder();
        if (positionId != 0) {
            (address positionOwner, uint32 positionMarket, bool positionIsLong,,,,,) =
                core.positions(positionId);
            if (
                positionOwner != msg.sender || positionMarket != marketId
                    || positionIsLong != isLong
            ) revert InvalidOrder();
        }
        if (collateralDelta != 0) {
            address(collateralToken).safeTransferFrom(msg.sender, address(this), collateralDelta);
        }
        id = nextOrderId++;
        orders[id] = Order(
            msg.sender,
            orderType,
            marketId,
            positionId,
            isLong,
            collateralDelta,
            sizeDeltaUsd,
            triggerPrice,
            acceptablePrice,
            uint64(block.timestamp),
            expiresAt,
            uint128(msg.value)
        );
        emit OrderCreated(id, msg.sender, orderType, expiresAt);
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
            address(collateralToken).safeTransfer(o.owner, o.collateralDelta);
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
        (bytes32 assetId, uint32 maxAge) =
            core.getMarketOracleConfig(o.marketId, o.orderType == OrderType.LimitIncrease);
        PriceData memory price = oracleRouter.getPrice(assetId, maxAge);
        if (price.updatedAt < o.submittedAt) revert InvalidOrder();
        if (!_triggered(o, price)) revert NotTriggered();
        delete orders[id];
        if (o.orderType == OrderType.LimitIncrease) {
            if (o.collateralDelta != 0) {
                collateralToken.approve(address(core), 0);
                collateralToken.approve(address(core), o.collateralDelta);
            }
            positionId = core.executeOrderIncrease(
                o.owner,
                o.marketId,
                o.positionId,
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
                address(collateralToken).safeTransfer(o.owner, o.collateralDelta);
            }
        }
        _sendNative(msg.sender, o.executionFee);
        emit OrderExecuted(id, msg.sender, positionId);
    }

    function _triggered(Order memory o, PriceData memory p) private pure returns (bool) {
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
            address(collateralToken).safeTransfer(recipient, o.collateralDelta);
        }
        _sendNative(recipient, o.executionFee);
    }

    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }
}
