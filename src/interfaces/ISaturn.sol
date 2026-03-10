// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title ISaturn
 * @notice Minimal interfaces for Saturn Protocol integration.
 * @dev Extracted from saturn-organization/saturn-yield-dollar on Sepolia.
 *
 *      Sepolia addresses (Chain 11155111):
 *        USDat:           0x23238f20b894f29041f48D88eE91131C395Aaa71
 *        sUSDat (proxy):  0x1383cB4A7f78a9b63b4928f6D4F77221b50f30a4
 *        StrcPriceOracle: 0x9C87dd67355c8Da172D3e2A2cADE1CcD15E23A58
 *        WithdrawalQueue: 0x3b2bd22089ED734979BB80A614d812b31B37ece4
 */

/// @notice sUSDat is ERC4626 with disabled withdraw()/redeem(). Exit via requestRedeem() only.
interface IStakedUSDat is IERC4626 {
    /// @notice Request async redemption. Burns shares into WithdrawalQueue NFT.
    function requestRedeem(uint256 shares, uint256 minUsdatReceived) external returns (uint256 requestId);

    /// @notice Claim all processed withdrawal requests for msg.sender.
    function claim() external returns (uint256 totalAmount);

    /// @notice Claim specific withdrawal request token IDs.
    function claimBatch(uint256[] calldata tokenIds) external returns (uint256 totalAmount);

    /// @notice Deposit with slippage protection.
    function depositWithMinShares(uint256 assets, address receiver, uint256 minShares)
        external
        returns (uint256 shares);

    /// @notice Mint with slippage protection.
    function mintWithMaxAssets(uint256 shares, address receiver, uint256 maxAssets)
        external
        returns (uint256 assets);

    /// @notice Current deposit fee in basis points (10 bps at launch).
    function depositFeeBps() external view returns (uint256);

    /// @notice Internally tracked USDat balance.
    function usdatBalance() external view returns (uint256);

    /// @notice Internally tracked STRC balance (6 decimals).
    function strcBalance() external view returns (uint256);

    /// @notice Amount of STRC currently vesting.
    function vestingAmount() external view returns (uint256);

    /// @notice Unvested reward amount.
    function getUnvestedAmount() external view returns (uint256);

    /// @notice Address of the withdrawal queue contract.
    function getWithdrawalQueue() external view returns (address);

    /// @notice Address of the STRC price oracle.
    function getStrcOracle() external view returns (address);

    /// @notice Check if address is blacklisted.
    function isBlacklisted(address account) external view returns (bool);
}

/// @notice STRC price oracle wrapping Chainlink with staleness + bounds checks.
interface IStrcPriceOracle {
    /// @notice Get validated STRC price. Reverts if stale or out of bounds [$20, $150].
    /// @return price The STRC price (8 decimals on Chainlink).
    /// @return oracleDecimals The number of decimals in the price.
    function getPrice() external view returns (uint256 price, uint8 oracleDecimals);

    /// @notice Current max staleness setting.
    function maxPriceStaleness() external view returns (uint256);

    /// @notice Price bounds.
    function minPrice() external view returns (uint256);
    function maxPrice() external view returns (uint256);
}
