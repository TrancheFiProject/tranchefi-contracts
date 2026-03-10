// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title  IAaveV3
 * @notice Minimal Aave V3 interfaces for TrancheFi lending adapter.
 * @dev    Extracted from Aave V3 core contracts on Arbitrum.
 *         Pool: 0x794a61358D6845594F94dc1DB02A252b5b4814aD (Arbitrum One)
 */

interface IPool {
    /**
     * @notice Supplies an amount of asset to the pool, receiving aTokens in return.
     * @param asset The address of the underlying asset to supply
     * @param amount The amount to supply
     * @param onBehalfOf The address that will receive the aTokens
     * @param referralCode Referral code (0 for none)
     */
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /**
     * @notice Withdraws an amount of asset from the pool, burning aTokens.
     * @param asset The address of the underlying asset to withdraw
     * @param amount The amount to withdraw (type(uint256).max for full balance)
     * @param to The address that will receive the withdrawn asset
     * @return The final amount withdrawn
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /**
     * @notice Borrows an amount of asset with variable rate.
     * @param asset The address of the underlying asset to borrow
     * @param amount The amount to borrow
     * @param interestRateMode 2 = variable rate
     * @param referralCode Referral code (0 for none)
     * @param onBehalfOf The address that will receive the debt
     */
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;

    /**
     * @notice Repays a borrowed amount.
     * @param asset The address of the underlying asset to repay
     * @param amount The amount to repay (type(uint256).max for full debt)
     * @param interestRateMode 2 = variable rate
     * @param onBehalfOf The address of the user who will get their debt reduced
     * @return The final amount repaid
     */
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);

    /**
     * @notice Returns the user account data across all reserves.
     * @param user The address of the user
     * @return totalCollateralBase Total collateral (in base currency, 8 decimals)
     * @return totalDebtBase Total debt (in base currency, 8 decimals)
     * @return availableBorrowsBase Available borrows (in base currency, 8 decimals)
     * @return currentLiquidationThreshold Weighted avg liquidation threshold (in bps, e.g. 8250 = 82.5%)
     * @return ltv Weighted avg loan-to-value (in bps)
     * @return healthFactor Health factor (WAD, 1e18 = 1.0)
     */
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IPoolDataProvider {
    /// @notice Returns the reserve data for a given asset.
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 unbacked,
            uint256 accruedToTreasuryScaled,
            uint256 totalAToken,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        );

    /**
     * @notice Returns the user reserve data for a given asset.
     * @param asset The address of the underlying asset
     * @param user The address of the user
     */
    function getUserReserveData(address asset, address user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        );

    /// @notice Returns the configuration data for a given asset.
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );
}
