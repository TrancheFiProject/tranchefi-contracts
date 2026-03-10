// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICurvePool} from "../../src/interfaces/ICurvePool.sol";

/// @dev Mock Curve pool for testing. Does 1:1 swaps between token0 (USDC) and token1 (sUSDat).
contract MockCurvePool is ICurvePool {
    IERC20 public token0; // USDC
    IERC20 public token1; // sUSDat

    uint256 public _priceOracle = 1e18; // 1:1 default

    constructor(address _token0, address _token1) {
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external override returns (uint256 dy) {
        dy = dx; // 1:1 for simplicity
        require(dy >= min_dy, "slippage");

        if (i == 0 && j == 1) {
            token0.transferFrom(msg.sender, address(this), dx);
            token1.transfer(msg.sender, dy);
        } else if (i == 1 && j == 0) {
            token1.transferFrom(msg.sender, address(this), dx);
            token0.transfer(msg.sender, dy);
        }
    }

    function get_dy(int128, int128, uint256 dx) external pure override returns (uint256) {
        return dx;
    }

    function balances(uint256 i) external view override returns (uint256) {
        if (i == 0) return token0.balanceOf(address(this));
        return token1.balanceOf(address(this));
    }

    function price_oracle() external view override returns (uint256) {
        return _priceOracle;
    }

    function last_price() external view override returns (uint256) {
        return _priceOracle;
    }

    // Test helper
    function setPriceOracle(uint256 p) external { _priceOracle = p; }
}
