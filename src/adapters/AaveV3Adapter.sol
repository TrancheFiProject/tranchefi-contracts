// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {IPool, IPoolDataProvider} from "../interfaces/IAaveV3.sol";

/**
 * @title  AaveV3Adapter
 * @author TrancheFi
 * @notice Concrete ILendingAdapter for Aave V3 on Arbitrum One.
 * @dev    Deposits sUSDat as collateral, borrows USDC against it.
 *
 *         Arbitrum One addresses:
 *           Aave V3 Pool:         0x794a61358D6845594F94dc1DB02A252b5b4814aD
 *           PoolDataProvider:     0x69FA688f1Dc47d4B5d8029D5a35FC7379531Bd43
 *           USDC:                 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
 *           sUSDat:               TBD (Saturn mainnet deployment)
 *
 *         Only the vault contract should call this adapter.
 */
contract AaveV3Adapter is ILendingAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ================================================================
    // IMMUTABLES
    // ================================================================

    /// @notice Aave V3 Pool contract
    IPool public immutable pool;

    /// @notice Aave V3 Pool Data Provider
    IPoolDataProvider public immutable dataProvider;

    /// @notice Collateral token (sUSDat)
    IERC20 public immutable collateralToken;

    /// @notice Debt token (USDC)
    IERC20 public immutable debtToken;

    /// @notice The vault that owns this adapter (only caller allowed)
    address public immutable vault;

    /// @notice Variable interest rate mode for Aave
    uint256 private constant VARIABLE_RATE = 2;

    // ================================================================
    // CONSTRUCTOR
    // ================================================================

    constructor(
        address _pool,
        address _dataProvider,
        address _collateralToken,
        address _debtToken,
        address _vault
    ) {
        require(_pool != address(0) && _dataProvider != address(0), "zero addr");
        require(_collateralToken != address(0) && _debtToken != address(0), "zero addr");
        require(_vault != address(0), "zero addr");

        pool = IPool(_pool);
        dataProvider = IPoolDataProvider(_dataProvider);
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        vault = _vault;

        // Pre-approve Aave pool for both tokens (max approval, standard pattern)
        IERC20(_collateralToken).forceApprove(_pool, type(uint256).max);
        IERC20(_debtToken).forceApprove(_pool, type(uint256).max);
    }

    // ================================================================
    // ACCESS CONTROL
    // ================================================================

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    // ================================================================
    // CORE OPERATIONS
    // ================================================================

    /**
     * @notice Deposit sUSDat as collateral on Aave V3.
     * @dev    Vault transfers sUSDat to adapter first, then adapter supplies to Aave.
     *         aTokens are held by this adapter contract.
     */
    function depositCollateral(uint256 amount) external override onlyVault nonReentrant {
        // Pull sUSDat from vault
        collateralToken.safeTransferFrom(vault, address(this), amount);
        // Supply to Aave (collateral on behalf of this adapter)
        pool.supply(address(collateralToken), amount, address(this), 0);
    }

    /**
     * @notice Withdraw sUSDat collateral from Aave V3.
     * @dev    Withdraws to vault directly.
     */
    function withdrawCollateral(uint256 amount) external override onlyVault nonReentrant {
        // Withdraw from Aave, send directly to vault
        pool.withdraw(address(collateralToken), amount, vault);
    }

    /**
     * @notice Borrow USDC against deposited sUSDat collateral.
     * @dev    Variable rate borrowing. USDC sent to vault.
     */
    function borrow(uint256 amount) external override onlyVault nonReentrant {
        // Borrow USDC at variable rate, on behalf of this adapter
        pool.borrow(address(debtToken), amount, VARIABLE_RATE, 0, address(this));
        // Send borrowed USDC to vault
        debtToken.safeTransfer(vault, amount);
    }

    /**
     * @notice Repay USDC debt on Aave V3.
     * @dev    Vault transfers USDC to adapter first, then adapter repays.
     */
    function repay(uint256 amount) external override onlyVault nonReentrant {
        // Pull USDC from vault
        debtToken.safeTransferFrom(vault, address(this), amount);
        // Repay variable rate debt
        pool.repay(address(debtToken), amount, VARIABLE_RATE, address(this));
    }

    // ================================================================
    // POSITION STATE
    // ================================================================

    /**
     * @notice Total sUSDat collateral deposited (from Aave aToken balance).
     * @dev    Uses getUserReserveData to get current aToken balance (includes accrued interest).
     */
    function collateralBalance() external view override returns (uint256) {
        (uint256 currentATokenBalance,,,,,,,,) = dataProvider.getUserReserveData(
            address(collateralToken), address(this)
        );
        return currentATokenBalance;
    }

    /**
     * @notice Total USDC debt outstanding (variable rate).
     */
    function debtBalance() external view override returns (uint256) {
        (,, uint256 currentVariableDebt,,,,,,) = dataProvider.getUserReserveData(
            address(debtToken), address(this)
        );
        return currentVariableDebt;
    }

    /**
     * @notice Current health factor from Aave (WAD, 1e18 = 1.0).
     * @dev    Returns type(uint256).max if no debt (Aave convention).
     */
    function healthFactor() external view override returns (uint256) {
        (,,,,, uint256 hf) = pool.getUserAccountData(address(this));
        return hf;
    }

    /**
     * @notice Current USDC variable borrow rate (WAD, annualized).
     * @dev    Aave returns rate in RAY (1e27). We convert to WAD (1e18).
     */
    function currentBorrowRate() external view override returns (uint256) {
        (,,,,,, uint256 variableBorrowRate,,,,,) = dataProvider.getReserveData(address(debtToken));
        // Aave rates are in RAY (1e27), convert to WAD (1e18)
        return variableBorrowRate / 1e9;
    }

    /**
     * @notice Maximum borrowable USDC given current collateral.
     * @dev    From Aave's getUserAccountData.availableBorrowsBase, converted from
     *         base currency (USD, 8 decimals) to USDC (6 decimals).
     */
    function maxBorrow() external view override returns (uint256) {
        (,, uint256 availableBorrowsBase,,,) = pool.getUserAccountData(address(this));
        // availableBorrowsBase is in 8 decimals (USD), USDC is 6 decimals
        return availableBorrowsBase / 1e2;
    }

    /**
     * @notice Liquidation threshold for sUSDat collateral (WAD).
     * @dev    Aave returns in bps (e.g. 8250 = 82.5%). Convert to WAD.
     */
    function liquidationThreshold() external view override returns (uint256) {
        (,, uint256 liqThreshold,,,,,,,) = dataProvider.getReserveConfigurationData(address(collateralToken));
        // Aave returns bps (8250 = 82.5%), convert to WAD
        return liqThreshold * 1e14; // bps → WAD: × 1e18 / 1e4
    }

    // ================================================================
    // EMERGENCY
    // ================================================================

    /**
     * @notice Emergency rescue of stuck tokens (admin only via vault).
     * @dev    In case of Aave migration or unexpected token behavior.
     */
    function rescueTokens(address token, uint256 amount) external onlyVault {
        IERC20(token).safeTransfer(vault, amount);
    }
}
