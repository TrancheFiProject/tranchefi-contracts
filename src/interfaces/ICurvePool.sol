// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title  ICurvePool
 * @notice Minimal Curve pool interface for sUSDat/USDC swaps and TWAP oracle.
 * @dev    Used for:
 *         1. Exit liquidity (swap sUSDat → USDC on withdrawal)
 *         2. Secondary oracle (TWAP price for dual-oracle safety check)
 */
interface ICurvePool {
    /// @notice Swap exact input tokens for output tokens.
    /// @param i Index of input token
    /// @param j Index of output token
    /// @param dx Amount of input token
    /// @param min_dy Minimum output (slippage protection)
    /// @return dy Amount of output token received
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy);

    /// @notice Get expected output for a swap (no state change).
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    /// @notice Get pool balances for a given token index.
    function balances(uint256 i) external view returns (uint256);

    /// @notice Get the price oracle (EMA) for the pool.
    /// @return Price in 1e18
    function price_oracle() external view returns (uint256);

    /// @notice Get the last stored price.
    function last_price() external view returns (uint256);
}
