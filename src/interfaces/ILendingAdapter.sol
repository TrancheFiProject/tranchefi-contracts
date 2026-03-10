// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/**
 * @title  ILendingAdapter
 * @notice Abstraction over Aave/Morpho lending protocols.
 * @dev    The vault calls this interface for all lending operations.
 *         Concrete implementations handle protocol-specific logic.
 *
 *         Why an adapter?
 *         - Vault logic doesn't change when switching Aave ↔ Morpho
 *         - Can deploy multiple adapters and migrate between them
 *         - Testable with mock adapter (no mainnet fork needed)
 *
 *         Terminology:
 *           collateral = sUSDat deposited to lending protocol
 *           debt       = USDC borrowed against collateral
 *           healthFactor = (collateral × liquidationThreshold) / debt
 */
interface ILendingAdapter {
    // ================================================================
    // CORE OPERATIONS
    // ================================================================

    /// @notice Deposit sUSDat as collateral on the lending protocol.
    /// @param amount Amount of sUSDat to deposit (6 decimals)
    function depositCollateral(uint256 amount) external;

    /// @notice Withdraw sUSDat collateral from the lending protocol.
    /// @param amount Amount of sUSDat to withdraw (6 decimals)
    function withdrawCollateral(uint256 amount) external;

    /// @notice Borrow USDC against deposited collateral.
    /// @param amount Amount of USDC to borrow (6 decimals)
    function borrow(uint256 amount) external;

    /// @notice Repay USDC debt.
    /// @param amount Amount of USDC to repay (6 decimals)
    function repay(uint256 amount) external;

    // ================================================================
    // POSITION STATE
    // ================================================================

    /// @notice Total sUSDat collateral deposited (6 decimals).
    function collateralBalance() external view returns (uint256);

    /// @notice Total USDC debt outstanding (6 decimals).
    function debtBalance() external view returns (uint256);

    /// @notice Current health factor (WAD). Returns type(uint256).max if no debt.
    function healthFactor() external view returns (uint256);

    /// @notice Current USDC variable borrow rate (WAD, annualized).
    function currentBorrowRate() external view returns (uint256);

    /// @notice Maximum borrowable USDC given current collateral (6 decimals).
    function maxBorrow() external view returns (uint256);

    /// @notice Liquidation threshold for sUSDat collateral (WAD, e.g. 0.825e18).
    function liquidationThreshold() external view returns (uint256);
}
