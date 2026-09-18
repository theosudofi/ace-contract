// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IPriceAdapter } from "../interfaces/IPriceAdapter.sol";
import { MathX } from "../libraries/MathX.sol";

struct PythPrice {
    int64 price;
    uint64 conf;
    int32 expo;
    uint256 publishTime;
}

interface IPyth {
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythPrice memory);
}

contract PythAdapter is IPriceAdapter {
    error InvalidConfig();
    error InvalidPrice();
    error ConfidenceTooWide();

    IPyth public immutable pyth;
    bytes32 public immutable priceId;
    uint16 public immutable maxConfidenceBps;

    constructor(address pyth_, bytes32 priceId_, uint16 maxConfidenceBps_) {
        if (
            pyth_ == address(0) || pyth_.code.length == 0 || priceId_ == bytes32(0)
                || maxConfidenceBps_ > 10_000
        ) revert InvalidConfig();
        pyth = IPyth(pyth_);
        priceId = priceId_;
        maxConfidenceBps = maxConfidenceBps_;
    }

    function getPrice(uint256 maxAge) external view returns (uint256 priceWad, uint256 updatedAt) {
        PythPrice memory value = pyth.getPriceNoOlderThan(priceId, maxAge);
        if (value.price <= 0) revert InvalidPrice();
        if (MathX.mulDiv(value.conf, 10_000, uint64(value.price)) > maxConfidenceBps) {
            revert ConfidenceTooWide();
        }
        priceWad = _toWad(uint64(value.price), value.expo);
        return (priceWad, value.publishTime);
    }

    function _toWad(uint256 value, int32 exponent) private pure returns (uint256) {
        // real price = value * 10^exponent; output = real price * 1e18.
        int256 scale = int256(18) + exponent;
        if (scale >= 0) {
            if (scale > 59) revert InvalidPrice();
            return value * (10 ** uint256(scale));
        }
        if (scale < -77) revert InvalidPrice();
        uint256 divisor = 10 ** uint256(-scale);
        uint256 result = value / divisor;
        if (result == 0) revert InvalidPrice();
        return result;
    }
}

