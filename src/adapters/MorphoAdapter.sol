// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {IMorpho, IMorphoOracle, IMorphoIrm, MarketParams, Market, Position, Id} from "../interfaces/IMorpho.sol";

/**
 * @title  MorphoAdapter
 * @author TrancheFi
 * @notice Concrete ILendingAdapter for Morpho Blue.
 * @dev    Deposits sUSDat as collateral, borrows USDC against it
 *         in a specific Morpho market defined by MarketParams.
 *
 *         Morpho Blue (same address all EVM chains):
 *           0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
 *
 *         Key differences from Aave:
 *           - No native health factor function (we calculate it)
 *           - Markets identified by params struct, not token address
 *           - Borrow rate is per-second, must annualize
 *           - LLTV is in MarketParams (already WAD)
 *           - Single contract for all operations
 */
contract MorphoAdapter is ILendingAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ================================================================
    // CONSTANTS
    // ================================================================

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365.25 days;

    // ================================================================
    // IMMUTABLES
    // ================================================================

    IMorpho public immutable morpho;
    IERC20 public immutable collateralToken; // sUSDat
    IERC20 public immutable loanToken;       // USDC
    address public immutable vault;

    /// @notice The specific Morpho market this adapter operates in.
    MarketParams public marketParams;

    /// @notice The market ID (keccak256 of encoded MarketParams).
    Id public marketId;

    // ================================================================
    // MODIFIERS
    // ================================================================

    modifier onlyVault() {
        require(msg.sender == vault, "MorphoAdapter: caller is not vault");
        _;
    }

    // ================================================================
    // CONSTRUCTOR
    // ================================================================

    /**
     * @param _morpho        Morpho Blue contract address.
     * @param _collateral    sUSDat token address.
     * @param _loan          USDC token address.
     * @param _oracle        Morpho oracle for sUSDat/USDC pricing.
     * @param _irm           Interest rate model address for the market.
     * @param _lltv          Liquidation LTV (WAD, e.g., 0.86e18 for 86%).
     * @param _vault         TrancheFi vault address (only caller).
     */
    constructor(
        address _morpho,
        address _collateral,
        address _loan,
        address _oracle,
        address _irm,
        uint256 _lltv,
        address _vault
    ) {
        morpho = IMorpho(_morpho);
        collateralToken = IERC20(_collateral);
        loanToken = IERC20(_loan);
        vault = _vault;

        marketParams = MarketParams({
            loanToken: _loan,
            collateralToken: _collateral,
            oracle: _oracle,
            irm: _irm,
            lltv: _lltv
        });

        // Compute market ID
        marketId = Id.wrap(keccak256(abi.encode(marketParams)));

        // Approve Morpho to spend both tokens (max approval, standard pattern)
        IERC20(_collateral).approve(_morpho, type(uint256).max);
        IERC20(_loan).approve(_morpho, type(uint256).max);
    }

    // ================================================================
    // CORE OPERATIONS
    // ================================================================

    /// @inheritdoc ILendingAdapter
    function depositCollateral(uint256 amount) external override onlyVault nonReentrant {
        // Pull sUSDat from vault
        collateralToken.safeTransferFrom(vault, address(this), amount);

        // Supply as collateral to Morpho market
        morpho.supplyCollateral(marketParams, amount, address(this), "");
    }

    /// @inheritdoc ILendingAdapter
    function withdrawCollateral(uint256 amount) external override onlyVault nonReentrant {
        // Withdraw collateral from Morpho
        morpho.withdrawCollateral(marketParams, amount, address(this), vault);
    }

    /// @inheritdoc ILendingAdapter
    function borrow(uint256 amount) external override onlyVault nonReentrant {
        // Borrow USDC from Morpho market, send directly to vault
        morpho.borrow(marketParams, amount, 0, address(this), vault);
    }

    /// @inheritdoc ILendingAdapter
    function repay(uint256 amount) external override onlyVault nonReentrant {
        // Pull USDC from vault
        loanToken.safeTransferFrom(vault, address(this), amount);

        // Repay debt on Morpho
        morpho.repay(marketParams, amount, 0, address(this), "");
    }

    // ================================================================
    // POSITION STATE (VIEW FUNCTIONS)
    // ================================================================

    /// @inheritdoc ILendingAdapter
    function collateralBalance() external view override returns (uint256) {
        Position memory pos = morpho.position(marketId, address(this));
        return pos.collateral;
    }

    /// @inheritdoc ILendingAdapter
    function debtBalance() external view override returns (uint256) {
        Position memory pos = morpho.position(marketId, address(this));
        if (pos.borrowShares == 0) return 0;

        // Convert borrow shares to assets
        Market memory mkt = morpho.market(marketId);
        // debt = borrowShares * totalBorrowAssets / totalBorrowShares (rounded up)
        return Math.mulDiv(
            uint256(pos.borrowShares),
            uint256(mkt.totalBorrowAssets),
            uint256(mkt.totalBorrowShares),
            Math.Rounding.Ceil
        );
    }

    /// @inheritdoc ILendingAdapter
    function healthFactor() external view override returns (uint256) {
        Position memory pos = morpho.position(marketId, address(this));
        if (pos.borrowShares == 0) return type(uint256).max;

        // Get debt in asset terms
        Market memory mkt = morpho.market(marketId);
        uint256 debt = Math.mulDiv(
            uint256(pos.borrowShares),
            uint256(mkt.totalBorrowAssets),
            uint256(mkt.totalBorrowShares),
            Math.Rounding.Ceil
        );

        if (debt == 0) return type(uint256).max;

        // Get collateral value in loan token terms
        // Oracle returns price scaled by 1e36
        uint256 oraclePrice = IMorphoOracle(marketParams.oracle).price();
        uint256 collateralValue = Math.mulDiv(uint256(pos.collateral), oraclePrice, 1e36);

        // HF = (collateralValue * LLTV) / debt
        return Math.mulDiv(collateralValue, marketParams.lltv, debt);
    }

    /// @inheritdoc ILendingAdapter
    function currentBorrowRate() external view override returns (uint256) {
        Market memory mkt = morpho.market(marketId);

        // Morpho IRM returns rate per second (WAD)
        uint256 ratePerSecond = IMorphoIrm(marketParams.irm).borrowRateView(marketParams, mkt);

        // Annualize: rate * seconds_per_year
        // ratePerSecond is WAD (1e18), result is WAD annualized
        return ratePerSecond * SECONDS_PER_YEAR;
    }

    /// @inheritdoc ILendingAdapter
    function maxBorrow() external view override returns (uint256) {
        Position memory pos = morpho.position(marketId, address(this));

        // Get collateral value in loan token terms
        uint256 oraclePrice = IMorphoOracle(marketParams.oracle).price();
        uint256 collateralValue = Math.mulDiv(uint256(pos.collateral), oraclePrice, 1e36);

        // Max borrow = collateral * LLTV
        uint256 maxDebt = Math.mulDiv(collateralValue, marketParams.lltv, WAD);

        // Subtract current debt
        Market memory mkt = morpho.market(marketId);
        uint256 currentDebt = 0;
        if (pos.borrowShares > 0) {
            currentDebt = Math.mulDiv(
                uint256(pos.borrowShares),
                uint256(mkt.totalBorrowAssets),
                uint256(mkt.totalBorrowShares),
                Math.Rounding.Ceil
            );
        }

        return maxDebt > currentDebt ? maxDebt - currentDebt : 0;
    }

    /// @inheritdoc ILendingAdapter
    function liquidationThreshold() external view override returns (uint256) {
        // Morpho LLTV is already in WAD
        return marketParams.lltv;
    }

    // ================================================================
    // EMERGENCY
    // ================================================================

    /// @notice Rescue tokens accidentally sent to this contract.
    /// @param token Token to rescue.
    /// @param to Recipient address.
    /// @param amount Amount to rescue.
    function rescueTokens(address token, address to, uint256 amount) external onlyVault {
        IERC20(token).safeTransfer(to, amount);
    }
}
