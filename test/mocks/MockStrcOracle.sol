// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IUnderlyingPriceOracle} from "../../src/interfaces/IVaultUnderlying.sol";

/// @dev Mock STRC oracle returning configurable price (8 decimals).
contract MockStrcOracle is IUnderlyingPriceOracle {
    uint256 public price = 100e8;  // $100.00 (at par)
    uint8 public constant DECIMALS = 8;

    function getPrice() external view returns (uint256, uint8) {
        return (price, DECIMALS);
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function maxPriceStaleness() external pure returns (uint256) {
        return 26 hours;
    }

    function minPrice() external pure returns (uint256) {
        return 20e8;
    }

    function maxPrice() external pure returns (uint256) {
        return 150e8;
    }
}
