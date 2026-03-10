// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/**
 * @title  IMorpho
 * @notice Minimal interface for Morpho Blue lending protocol.
 * @dev    Morpho Blue uses isolated markets identified by MarketParams.
 *         Each market is a unique combination of:
 *           - loanToken (what you borrow, e.g., USDC)
 *           - collateralToken (what you deposit, e.g., sUSDat)
 *           - oracle (price feed for the pair)
 *           - irm (interest rate model)
 *           - lltv (liquidation LTV, e.g., 86%)
 *
 *         Morpho Blue contract (same on all EVM chains):
 *           0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
 */

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/// @dev Market ID is the keccak256 hash of the encoded MarketParams
type Id is bytes32;

interface IMorpho {
    /// @notice Supply collateral to a market.
    /// @param marketParams The market to supply to.
    /// @param assets Amount of collateral tokens to supply.
    /// @param onBehalf Address to credit the collateral to.
    /// @param data Callback data (empty for simple deposits).
    function supplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;

    /// @notice Withdraw collateral from a market.
    /// @param marketParams The market to withdraw from.
    /// @param assets Amount of collateral tokens to withdraw.
    /// @param onBehalf Address whose collateral to withdraw.
    /// @param receiver Address to receive the collateral.
    function withdrawCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;

    /// @notice Borrow loan tokens from a market.
    /// @param marketParams The market to borrow from.
    /// @param assets Amount of loan tokens to borrow (0 if using shares).
    /// @param shares Amount of borrow shares (0 if using assets).
    /// @param onBehalf Address to take the debt.
    /// @param receiver Address to receive borrowed tokens.
    /// @return assetsBorrowed Actual assets borrowed.
    /// @return sharesBorrowed Shares of debt taken.
    function borrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    /// @notice Repay loan tokens to a market.
    /// @param marketParams The market to repay to.
    /// @param assets Amount of loan tokens to repay (0 if using shares).
    /// @param shares Amount of borrow shares to repay (0 if using assets).
    /// @param onBehalf Address whose debt to repay.
    /// @param data Callback data (empty for simple repays).
    /// @return assetsRepaid Actual assets repaid.
    /// @return sharesRepaid Shares of debt repaid.
    function repay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// @notice Get market state.
    function market(Id id) external view returns (Market memory);

    /// @notice Get a position in a market.
    function position(Id id, address user) external view returns (Position memory);

    /// @notice Get the market ID from market params.
    function idToMarketParams(Id id) external view returns (MarketParams memory);
}

/// @notice Morpho oracle interface used to get price of collateral in loan token terms.
interface IMorphoOracle {
    /// @notice Returns the price of 1 unit of collateral in loan token terms, scaled by 1e36.
    function price() external view returns (uint256);
}

/// @notice Morpho IRM (Interest Rate Model) interface.
interface IMorphoIrm {
    /// @notice Returns the borrow rate per second for a market, scaled by 1e18.
    function borrowRateView(MarketParams calldata marketParams, Market calldata mkt) external view returns (uint256);
}
