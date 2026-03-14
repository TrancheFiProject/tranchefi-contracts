// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IStakedUSDat, IStrcPriceOracle} from "./interfaces/ISaturn.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {TrancheToken} from "./tokens/TrancheToken.sol";

/**
 * @title  TrancheFiVault (v2 — Production Spec)
 * @author TrancheFi
 * @notice Structured credit vault creating senior/junior tranches from leveraged sUSDat.
 * @dev    Full implementation of Whitepaper v6 including:
 *           - Leverage loop execution via lending adapter (Aave/Morpho)
 *           - Withdrawal queue with FIFO, epoch caps, senior priority
 *           - Health factor monitoring with four-tier deleveraging cascade
 *           - Borrow cost circuit breaker
 *           - Dual oracle safety (Saturn internal + Curve TWAP)
 *           - Bunker mode for mass withdrawal protection
 *           - USDC liquidity reserve (5-10% of TVL)
 *           - TVL cap as % of sUSDat secondary market depth
 */
contract TrancheFiVault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ================================================================
    // CONSTANTS — Whitepaper v6 Parameters
    // ================================================================

    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_DECIMALS = 1e6;

    // --- Roles ---
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // --- Senior tranche (Section 5) ---
    uint256 public constant SR_GROSS_APY = 0.085e18;
    uint256 public constant SR_MGMT_FEE  = 0.005e18;

    // --- Junior tranche (Section 8) ---
    uint256 public constant JR_MGMT_FEE  = 0.005e18;
    uint256 public constant JR_PERF_FEE  = 0.10e18;

    // --- Yield sources ---
    uint256 public constant SUSDAT_YIELD   = 0.1035e18;
    uint256 public constant DEFAULT_BORROW = 0.07e18;

    // --- Leverage (Section 7) ---
    uint256 public constant TARGET_LEVERAGE = 1.75e18;
    uint256 public constant LEV_MIN        = 1.00e18;  // Emergency minimum
    uint256 public constant LEV_MAX        = 2.00e18;
    uint256 public constant LEV_RELEV_CAP  = 0.25e18;  // Max re-leverage per epoch

    // --- Tranche ratio (Section 9.2) ---
    uint256 public constant RATIO_TARGET = 0.70e18;
    uint256 public constant RATIO_MIN    = 0.68e18;
    uint256 public constant RATIO_MAX    = 0.72e18;

    // --- Health factor (Section 9.5) ---
    uint256 public constant HF_TARGET     = 2.0e18;
    uint256 public constant HF_FREEZE     = 1.8e18;
    uint256 public constant HF_DELEVERAGE = 1.6e18;
    uint256 public constant HF_ACCELERATE = 1.3e18;
    uint256 public constant HF_EMERGENCY  = 1.1e18;

    // --- Withdrawal gates (Section 10.2) ---
    uint256 public constant WITHDRAWAL_CAP   = 0.15e18;
    uint256 public constant BUNKER_THRESHOLD = 0.25e18;
    uint256 public constant BUNKER_CAP       = 0.10e18;
    uint256 public constant RESERVE_TARGET   = 0.075e18;

    // --- Borrow cost circuit breaker (Section 9.8) ---
    uint256 public constant BORROW_FREEZE    = 0.10e18;   // 10%: freeze leverage increases
    uint256 public constant BORROW_DELEVERAGE = 0.12e18;  // 12%: begin deleveraging
    uint256 public constant BORROW_EMERGENCY = 0.15e18;   // 15%: accelerated deleveraging

    // --- Dual oracle (Section 9.7) ---
    uint256 public constant ORACLE_DEVIATION_MAX = 0.02e18; // 2% max divergence
    uint256 public constant MIN_DEPOSIT = 100e6; // $100 minimum deposit (H3: inflation attack prevention)

    // --- Epoch ---
    uint256 public constant EPOCH_SECONDS = 7 days;
    uint256 public constant EPOCHS_PER_YEAR = 52;

    // ================================================================
    // EXTERNAL CONTRACTS
    // ================================================================

    IERC20 public immutable usdc;
    IERC20 public immutable usdatToken;
    IStakedUSDat public immutable sUsdat;
    IStrcPriceOracle public immutable strcOracle;

    // ================================================================
    // MUTABLE EXTERNAL REFERENCES (upgradeable by admin)
    // ================================================================

    ILendingAdapter public lendingAdapter;
    ICurvePool public curvePool;

    // ================================================================
    // TRANCHE TOKENS
    // ================================================================

    TrancheToken public immutable sdcSenior;
    TrancheToken public immutable sdcJunior;

    // --- Timelock (Section 9.10) ---
    uint256 public constant TIMELOCK_DELAY = 7 days;

    struct TimelockRequest {
        bytes32 actionHash;
        uint256 executeAfter;
        bool executed;
    }

    mapping(uint256 => TimelockRequest) public timelockRequests;
    uint256 public nextTimelockId;

    event TimelockQueued(uint256 indexed id, bytes32 actionHash, uint256 executeAfter);
    event TimelockExecuted(uint256 indexed id);

    // ================================================================
    // VAULT STATE
    // ================================================================

    uint256 public seniorNAV;
    uint256 public juniorNAV;
    uint256 public currentLeverage;
    uint256 public currentEpoch;
    uint256 public lastEpochTimestamp;
    uint256 public accruedFees;
    bool public isShutdown;

    // --- USDC Reserve (Section 10.1) ---
    /// @notice USDC held in reserve (not looped), for instant withdrawals
    uint256 public usdcReserve;

    // --- Bunker mode (Section 10.2) ---
    bool public bunkerMode;

    // --- TVL cap ---
    /// @notice Maximum TVL as set by governance (0 = no cap)
    uint256 public tvlCap;

    // --- Oracle state ---
    bool public oracleCircuitBroken;

    // ================================================================
    // WITHDRAWAL QUEUE (Section 9.3)
    // ================================================================

    struct WithdrawalRequest {
        address user;
        bool isSenior;
        uint256 shares;       // Tranche token shares to burn
        uint256 epoch;        // Epoch when request was submitted
        bool fulfilled;
        uint256 usdcAmount;   // USDC to claim (set when fulfilled)
    }

    /// @notice Auto-incrementing request ID
    uint256 public nextRequestId;

    /// @notice All withdrawal requests by ID
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    /// @notice Queued senior withdrawal shares this epoch
    uint256 public queuedSeniorShares;

    /// @notice Queued junior withdrawal shares this epoch
    uint256 public queuedJuniorShares;

    // ================================================================
    // DEPOSIT QUEUE — Async ERC-7540 pattern (Section 9.1-9.2)
    // ================================================================

    struct DepositRequest {
        address user;
        bool isSenior;
        uint256 assets;        // USDC deposited
        uint256 epoch;         // Epoch when request was submitted
        bool processed;        // True after epoch settlement processes it
        uint256 shares;        // Shares to claim (set when processed)
    }

    uint256 public nextDepositRequestId;
    mapping(uint256 => DepositRequest) public depositRequests;

    /// @notice Pending USDC waiting for deployment (held between request and epoch settlement)
    uint256 public pendingDeposits;

    /// @notice Fix 4: Track pending deposits per tranche for accurate ratio/TVL checks
    uint256 public pendingSeniorDeposits;
    uint256 public pendingJuniorDeposits;

    // --- Queue cursors (H5/M3 fix: avoid O(n) full scan) ---
    uint256 public lastProcessedDepositId;
    uint256 public lastProcessedWithdrawalId;

    // ================================================================
    // STRUCTS
    // ================================================================

    struct SignalData {
        uint256 borrowRate;
        uint256 strcPrice;       // 8 decimals
        uint256 prevStrcPrice;   // 8 decimals
    }

    struct WaterfallResult {
        uint256 poolIncome;
        int256  poolMTM;
        uint256 seniorCoupon;
        uint256 seniorMgmtFee;
        uint256 juniorMgmtFee;
        uint256 perfFee;
        int256  juniorNetDelta;
        uint256 seniorImpairment;
    }

    // ================================================================
    // EVENTS
    // ================================================================

    event Deposited(address indexed user, bool indexed isSenior, uint256 assets, uint256 shares);
    event DepositRequested(address indexed user, bool indexed isSenior, uint256 assets, uint256 requestId);
    event DepositProcessed(uint256 indexed requestId, uint256 shares);
    event DepositClaimed(address indexed user, uint256 indexed requestId, uint256 shares);
    event EpochSettled(uint256 indexed epoch, uint256 seniorNAV, uint256 juniorNAV, uint256 leverage, uint256 healthFactor);
    event WaterfallExecuted(uint256 indexed epoch, WaterfallResult result);
    event WithdrawalRequested(address indexed user, bool indexed isSenior, uint256 shares, uint256 requestId);
    event WithdrawalFulfilled(uint256 indexed requestId, uint256 usdcAmount);
    event WithdrawalClaimed(address indexed user, uint256 indexed requestId, uint256 usdcAmount);
    event LeverageAdjusted(uint256 oldLev, uint256 newLev, uint256 collateral, uint256 debt);
    event BunkerModeActivated(uint256 epoch);
    event BunkerModeDeactivated(uint256 epoch);
    event OracleCircuitBroken(uint256 saturnPrice, uint256 curvePrice);
    event EmergencyShutdown(uint256 timestamp);
    event EmergencyClaim(address indexed user, bool indexed isSenior, uint256 usdcAmount);
    event EmergencyDeleveraged(uint256 healthFactor, uint256 newLeverage);

    // ================================================================
    // ERRORS
    // ================================================================

    error ZeroAmount();
    error RatioBroken();
    error EpochTooSoon();
    error VaultShutdown();
    error NotShutdown();
    error TVLCapExceeded();
    error InsufficientShares();
    error RequestNotFulfilled();
    error RequestAlreadyClaimed();
    error OracleDeviation();
    error NotRequestOwner();
    error DepositNotProcessed();
    error DepositAlreadyClaimed();

    // ================================================================
    // CONSTRUCTOR
    // ================================================================

    constructor(
        address _usdc,
        address _usdat,
        address _sUsdat,
        address _strcOracle,
        address _lendingAdapter,
        address _curvePool,
        address _admin,
        address _keeper
    ) {
        require(_usdc != address(0) && _usdat != address(0), "zero addr");
        require(_sUsdat != address(0) && _strcOracle != address(0), "zero addr");

        usdc = IERC20(_usdc);
        usdatToken = IERC20(_usdat);
        sUsdat = IStakedUSDat(_sUsdat);
        strcOracle = IStrcPriceOracle(_strcOracle);
        lendingAdapter = ILendingAdapter(_lendingAdapter);
        curvePool = ICurvePool(_curvePool);

        sdcSenior = new TrancheToken("TrancheFi Senior", "sdcSENIOR", address(this));
        sdcJunior = new TrancheToken("TrancheFi Junior", "sdcJUNIOR", address(this));

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
        _grantRole(GUARDIAN_ROLE, _admin);

        currentLeverage = TARGET_LEVERAGE;
        lastEpochTimestamp = block.timestamp;
    }

    // ================================================================
    // DEPOSIT FUNCTIONS — Async ERC-7540 Pattern (Section 9.1-9.2)
    // ================================================================

    /**
     * @notice Request deposit into a tranche. USDC is taken immediately,
     *         shares are minted at next epoch settlement (prevents MEV/front-running).
     * @dev    Implements request/claim pattern per ERC-7540, matching Saturn's
     *         modified ERC-4626 async model.
     * @param assets Amount of USDC to deposit (6 decimals)
     * @param isSenior True for senior tranche, false for junior
     * @return requestId Unique ID for this deposit request
     */
    function requestDeposit(uint256 assets, bool isSenior) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (isShutdown) revert VaultShutdown();
        if (assets == 0) revert ZeroAmount();
        require(assets >= MIN_DEPOSIT, "below minimum deposit");
        // Fix 4: Include pending deposits in TVL and ratio checks
        _checkTVLCapWithPending(assets);
        if (_wouldBreakRatioWithPending(assets, isSenior)) revert RatioBroken();

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        pendingDeposits += assets;
        if (isSenior) {
            pendingSeniorDeposits += assets;
        } else {
            pendingJuniorDeposits += assets;
        }

        requestId = nextDepositRequestId++;
        depositRequests[requestId] = DepositRequest({
            user: msg.sender,
            isSenior: isSenior,
            assets: assets,
            epoch: currentEpoch,
            processed: false,
            shares: 0
        });

        emit DepositRequested(msg.sender, isSenior, assets, requestId);
    }

    /**
     * @notice Claim shares after deposit request has been processed at epoch settlement.
     * @param requestId The deposit request ID
     */
    function claimDeposit(uint256 requestId) external nonReentrant {
        DepositRequest storage req = depositRequests[requestId];
        if (req.user != msg.sender) revert NotRequestOwner();
        if (!req.processed) revert DepositNotProcessed();
        if (req.shares == 0) revert DepositAlreadyClaimed();

        uint256 shares = req.shares;
        req.shares = 0; // prevent double-claim

        TrancheToken token = req.isSenior ? sdcSenior : sdcJunior;
        IERC20(address(token)).safeTransfer(msg.sender, shares);

        emit DepositClaimed(msg.sender, requestId, shares);
    }


    /**
     * @notice Cancel an unprocessed deposit request and reclaim USDC.
     * @param requestId The deposit request ID
     */
    function cancelDeposit(uint256 requestId) external nonReentrant {
        DepositRequest storage req = depositRequests[requestId];
        if (req.user != msg.sender) revert NotRequestOwner();
        require(!req.processed, "already processed");
        require(req.assets > 0, "already cancelled");

        uint256 assets = req.assets;
        req.assets = 0; // prevent double-cancel

        pendingDeposits -= assets;
        if (req.isSenior) {
            pendingSeniorDeposits = pendingSeniorDeposits > assets ? pendingSeniorDeposits - assets : 0;
        } else {
            pendingJuniorDeposits = pendingJuniorDeposits > assets ? pendingJuniorDeposits - assets : 0;
        }

        usdc.safeTransfer(msg.sender, assets);
    }

    /**
     * @dev Process pending deposit requests at epoch settlement.
     *      Shares are priced at current NAV (post-waterfall), deployed into sUSDat + leverage.
     */
    function _processDeposits() internal {
        // Advance cursor past any already-processed entries first
        while (lastProcessedDepositId < nextDepositRequestId && 
               (depositRequests[lastProcessedDepositId].processed || depositRequests[lastProcessedDepositId].assets == 0)) {
            lastProcessedDepositId++;
        }

        for (uint256 i = lastProcessedDepositId; i < nextDepositRequestId; i++) {
            DepositRequest storage req = depositRequests[i];
            if (req.processed || req.assets == 0) continue;

            // M2 FIX: Skip deposit into wiped tranche (NAV=0 but supply>0)
            uint256 nav = req.isSenior ? seniorNAV : juniorNAV;
            TrancheToken token = req.isSenior ? sdcSenior : sdcJunior;
            if (nav == 0 && token.totalSupply() > 0) continue;

            uint256 shares = _calculateShares(req.assets, nav, token.totalSupply());
            token.mint(address(this), shares);

            if (req.isSenior) {
                seniorNAV += req.assets;
            } else {
                juniorNAV += req.assets;
            }

            uint256 reservePortion = _mulWad(req.assets, RESERVE_TARGET);
            uint256 deployPortion = req.assets - reservePortion;
            usdcReserve += reservePortion;

            if (deployPortion > 0) {
                _deployCapital(deployPortion);
            }

            req.processed = true;
            req.shares = shares;
            pendingDeposits -= req.assets;
            if (req.isSenior) {
                pendingSeniorDeposits = pendingSeniorDeposits > req.assets ? pendingSeniorDeposits - req.assets : 0;
            } else {
                pendingJuniorDeposits = pendingJuniorDeposits > req.assets ? pendingJuniorDeposits - req.assets : 0;
            }

            emit DepositProcessed(i, shares);
        }

        // Advance cursor past everything we just processed
        while (lastProcessedDepositId < nextDepositRequestId && 
               (depositRequests[lastProcessedDepositId].processed || depositRequests[lastProcessedDepositId].assets == 0)) {
            lastProcessedDepositId++;
        }
    }

    /**
     * @notice Direct deposit (synchronous) — available only during bootstrap (empty vault).
     * @dev    Once both tranches have capital, use requestDeposit/claimDeposit.
     */
    function depositSenior(uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (isShutdown) revert VaultShutdown();
        if (assets == 0) revert ZeroAmount();
        require(assets >= MIN_DEPOSIT, "below minimum deposit");
        _checkTVLCapWithPending(assets);
        // Ratio check: skip during bootstrap, enforce after
        if (seniorNAV > 0 && juniorNAV > 0) {
            if (_wouldBreakRatioWithPending(assets, true)) revert RatioBroken();
        }

        usdc.safeTransferFrom(msg.sender, address(this), assets);

        uint256 reservePortion = _mulWad(assets, RESERVE_TARGET);
        uint256 deployPortion = assets - reservePortion;
        usdcReserve += reservePortion;

        shares = _calculateShares(assets, seniorNAV, sdcSenior.totalSupply());
        sdcSenior.mint(msg.sender, shares);
        seniorNAV += assets;

        if (deployPortion > 0) {
            _deployCapital(deployPortion);
        }

        emit Deposited(msg.sender, true, assets, shares);
    }

    function depositJunior(uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (isShutdown) revert VaultShutdown();
        if (assets == 0) revert ZeroAmount();
        require(assets >= MIN_DEPOSIT, "below minimum deposit");
        _checkTVLCapWithPending(assets);
        // Ratio check: skip during bootstrap, enforce after
        if (seniorNAV > 0 && juniorNAV > 0) {
            if (_wouldBreakRatioWithPending(assets, false)) revert RatioBroken();
        }

        usdc.safeTransferFrom(msg.sender, address(this), assets);

        uint256 reservePortion = _mulWad(assets, RESERVE_TARGET);
        uint256 deployPortion = assets - reservePortion;
        usdcReserve += reservePortion;

        shares = _calculateShares(assets, juniorNAV, sdcJunior.totalSupply());
        sdcJunior.mint(msg.sender, shares);
        juniorNAV += assets;

        if (deployPortion > 0) {
            _deployCapital(deployPortion);
        }

        emit Deposited(msg.sender, false, assets, shares);
    }

    // ================================================================
    // WITHDRAWAL SYSTEM (Section 9.3, 10)
    // ================================================================

    /**
     * @notice Instant withdrawal from reserve. Burns shares, sends USDC immediately.
     * @param shares Number of tranche token shares to redeem
     * @param isSenior True for senior, false for junior
     * @return usdcOut Amount of USDC sent
     * @return queued True if request was queued instead of instant
     */
    /// @notice Cumulative instant redemptions this epoch (for cap enforcement)
    uint256 public epochInstantRedeemed;
    uint256 public lastInstantRedeemEpoch;

    function instantRedeem(uint256 shares, bool isSenior) external nonReentrant whenNotPaused returns (uint256 usdcOut, bool queued) {
        if (isShutdown) revert VaultShutdown();        // M1: shutdown check
        if (shares == 0) revert ZeroAmount();
        require(!bunkerMode, "bunker mode: use requestRedeem"); // H1: bunker check

        TrancheToken token = isSenior ? sdcSenior : sdcJunior;
        if (token.balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint256 nav = isSenior ? seniorNAV : juniorNAV;
        uint256 supply = token.totalSupply();
        if (supply == 0) revert ZeroAmount();
        usdcOut = (shares * nav) / supply;

        // H1: Enforce per-epoch withdrawal cap on instant redeems
        if (lastInstantRedeemEpoch != currentEpoch) {
            epochInstantRedeemed = 0;
            lastInstantRedeemEpoch = currentEpoch;
        }
        uint256 totalTVL = seniorNAV + juniorNAV;
        uint256 epochCap = _mulWad(totalTVL, WITHDRAWAL_CAP);
        if (epochInstantRedeemed + usdcOut > epochCap) {
            // Over cap — fall back to queue
            IERC20(address(token)).safeTransferFrom(msg.sender, address(this), shares);
            uint256 requestId = nextRequestId++;
            withdrawalRequests[requestId] = WithdrawalRequest({
                user: msg.sender,
                isSenior: isSenior,
                shares: shares,
                epoch: currentEpoch,
                fulfilled: false,
                usdcAmount: 0
            });
            if (isSenior) {
                queuedSeniorShares += shares;
            } else {
                queuedJuniorShares += shares;
            }
            emit WithdrawalRequested(msg.sender, isSenior, shares, requestId);
            return (0, true);
        }

        // Reserve check
        if (usdcOut <= usdcReserve) {
            IERC20(address(token)).safeTransferFrom(msg.sender, address(this), shares);
            token.burn(address(this), shares);
            if (isSenior) {
                seniorNAV = seniorNAV > usdcOut ? seniorNAV - usdcOut : 0;
            } else {
                juniorNAV = juniorNAV > usdcOut ? juniorNAV - usdcOut : 0;
            }
            usdcReserve -= usdcOut;
            epochInstantRedeemed += usdcOut;
            usdc.safeTransfer(msg.sender, usdcOut);
            emit WithdrawalClaimed(msg.sender, type(uint256).max, usdcOut); // M3: sentinel ID
            return (usdcOut, false);
        }

        // Reserve insufficient — fall back to queue
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), shares);
        uint256 requestId = nextRequestId++;
        withdrawalRequests[requestId] = WithdrawalRequest({
            user: msg.sender,
            isSenior: isSenior,
            shares: shares,
            epoch: currentEpoch,
            fulfilled: false,
            usdcAmount: 0
        });
        if (isSenior) {
            queuedSeniorShares += shares;
        } else {
            queuedJuniorShares += shares;
        }
        emit WithdrawalRequested(msg.sender, isSenior, shares, requestId);
        return (0, true);
    }

    /**
     * @notice Instant withdrawal from reserve. Burns shares, sends USDC immediately.
     * @param shares Number of tranche token shares to redeem
     * @param isSenior True for senior, false for junior
     * @return usdcOut Amount of USDC sent
     * @return queued True if request was queued instead of instant
     */

    /**
     * @notice Request withdrawal from a tranche. Enters epoch queue.
     * @param shares Number of tranche token shares to redeem
     * @param isSenior True for senior, false for junior
     * @return requestId Unique ID for this withdrawal request
     */
    function requestRedeem(uint256 shares, bool isSenior) external nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();

        TrancheToken token = isSenior ? sdcSenior : sdcJunior;
        if (token.balanceOf(msg.sender) < shares) revert InsufficientShares();

        // Transfer shares to vault (held until fulfilled and claimed)
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), shares);

        requestId = nextRequestId++;
        withdrawalRequests[requestId] = WithdrawalRequest({
            user: msg.sender,
            isSenior: isSenior,
            shares: shares,
            epoch: currentEpoch,
            fulfilled: false,
            usdcAmount: 0
        });

        if (isSenior) {
            queuedSeniorShares += shares;
        } else {
            queuedJuniorShares += shares;
        }

        emit WithdrawalRequested(msg.sender, isSenior, shares, requestId);
    }

    /**
     * @notice Claim a fulfilled withdrawal request. Burns shares, sends USDC.
     * @param requestId The withdrawal request ID
     */
    function claimWithdrawal(uint256 requestId) external nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        if (req.user != msg.sender) revert NotRequestOwner();
        if (!req.fulfilled) revert RequestNotFulfilled();
        if (req.usdcAmount == 0) revert RequestAlreadyClaimed();

        uint256 amount = req.usdcAmount;
        req.usdcAmount = 0; // prevent double-claim

        // Shares already burned at fulfillment time (Fix 1: fair pricing)
        // Just send USDC
        usdc.safeTransfer(msg.sender, amount);

        emit WithdrawalClaimed(msg.sender, requestId, amount);
    }

    /**
     * @notice Process withdrawal queue. Called by keeper during epoch settlement.
     * @dev    Senior-first priority. Epoch caps enforced. Three-layer liquidity stack.
     */
    function _processWithdrawals() internal {
        uint256 totalTVL = seniorNAV + juniorNAV;
        if (totalTVL == 0) return;

        // Determine per-epoch cap
        uint256 capRate = bunkerMode ? BUNKER_CAP : WITHDRAWAL_CAP;

        // Check bunker mode trigger: >25% of TVL queued
        uint256 totalQueuedValue = _sharesToAssets(queuedSeniorShares, seniorNAV, sdcSenior.totalSupply())
                                 + _sharesToAssets(queuedJuniorShares, juniorNAV, sdcJunior.totalSupply());

        if (!bunkerMode && totalQueuedValue > _mulWad(totalTVL, BUNKER_THRESHOLD)) {
            bunkerMode = true;
            capRate = BUNKER_CAP;
            emit BunkerModeActivated(currentEpoch);
        }

        // Process senior first (priority), then junior
        uint256 availableLiquidity = usdcReserve;

        // Senior withdrawals
        uint256 srCap = _mulWad(seniorNAV, capRate);
        uint256 srProcessed = _processTrancheWithdrawals(true, srCap, availableLiquidity);
        availableLiquidity = availableLiquidity > srProcessed ? availableLiquidity - srProcessed : 0;

        // Junior withdrawals (only after senior fully served)
        uint256 jrCap = _mulWad(juniorNAV, capRate);
        _processTrancheWithdrawals(false, jrCap, availableLiquidity);

        // Check bunker mode exit: queued < 10% TVL
        if (bunkerMode) {
            uint256 remainingQueued = _sharesToAssets(queuedSeniorShares, seniorNAV, sdcSenior.totalSupply())
                                   + _sharesToAssets(queuedJuniorShares, juniorNAV, sdcJunior.totalSupply());
            if (remainingQueued < _mulWad(totalTVL, 0.10e18)) {
                bunkerMode = false;
                emit BunkerModeDeactivated(currentEpoch);
            }
        }
    }

    /**
     * @dev Process withdrawal requests for one tranche within cap and liquidity limits.
     *      Uses three-layer withdrawal stack: reserve → Curve → Saturn async.
     *      Returns total USDC distributed.
     */
    function _processTrancheWithdrawals(
        bool isSenior,
        uint256 cap,
        uint256 availableLiquidity
    ) internal returns (uint256 totalDistributed) {
        uint256 processedValue;

        // Advance cursor past fulfilled entries first
        while (lastProcessedWithdrawalId < nextRequestId && withdrawalRequests[lastProcessedWithdrawalId].fulfilled) {
            lastProcessedWithdrawalId++;
        }

        for (uint256 i = lastProcessedWithdrawalId; i < nextRequestId; i++) {
            WithdrawalRequest storage req = withdrawalRequests[i];
            if (req.fulfilled || req.isSenior != isSenior || req.shares == 0) continue;

            uint256 nav = isSenior ? seniorNAV : juniorNAV;
            uint256 supply = isSenior ? sdcSenior.totalSupply() : sdcJunior.totalSupply();
            uint256 assetValue = _sharesToAssets(req.shares, nav, supply);

            // H4 FIX: skip oversized, don't block entire queue
            if (processedValue + assetValue > cap) continue;

            uint256 usdcOut;
            if (availableLiquidity >= assetValue) {
                usdcOut = assetValue;
                usdcReserve = usdcReserve > assetValue ? usdcReserve - assetValue : 0;
                availableLiquidity -= assetValue;
            } else {
                // FIX 5 (W1): Don't zero reserve — track precisely
                uint256 fromReserve = availableLiquidity;
                uint256 deficit = assetValue - fromReserve;
                uint256 unwound = _unwindForWithdrawal(deficit);
                usdcOut = fromReserve + unwound;
                usdcReserve = usdcReserve > fromReserve ? usdcReserve - fromReserve : 0;
                availableLiquidity = 0;
            }

            req.fulfilled = true;
            req.usdcAmount = usdcOut;
            processedValue += assetValue;
            totalDistributed += usdcOut;

            // FIX 1: Burn shares NOW (not at claim) so totalSupply decreases with NAV
            // This ensures equal per-share pricing for all withdrawers in same epoch
            TrancheToken token = isSenior ? sdcSenior : sdcJunior;
            token.burn(address(this), req.shares);

            // A5 FIX: Reduce NAV by actual USDC paid out
            if (isSenior) {
                seniorNAV = seniorNAV > usdcOut ? seniorNAV - usdcOut : 0;
                queuedSeniorShares -= req.shares;
            } else {
                juniorNAV = juniorNAV > usdcOut ? juniorNAV - usdcOut : 0;
                queuedJuniorShares -= req.shares;
            }

            emit WithdrawalFulfilled(i, usdcOut);
        }

        // Advance cursor past everything fulfilled
        while (lastProcessedWithdrawalId < nextRequestId && withdrawalRequests[lastProcessedWithdrawalId].fulfilled) {
            lastProcessedWithdrawalId++;
        }
    }

    // ================================================================
    // LEVERAGE LOOP EXECUTION (Section 6.1)
    // ================================================================

    /**
     * @notice Deploy USDC capital into leveraged sUSDat position.
     * @dev    USDC → sUSDat (via Saturn/Curve) → deposit as collateral →
     *         borrow USDC → repeat until target leverage reached.
     */
    function _deployCapital(uint256 usdcAmount) internal {
        // Convert USDC to sUSDat
        uint256 susdatAmount = _usdcToSUsdat(usdcAmount);

        // Deposit sUSDat as collateral on lending protocol
        IERC20(address(sUsdat)).forceApprove(address(lendingAdapter), susdatAmount);
        lendingAdapter.depositCollateral(susdatAmount);
    }

    /**
     * @notice Rebalance leverage to match target.
     * @dev    Called during epoch settlement after leverage is computed.
     *         If target > current: borrow more USDC, convert to sUSDat, deposit
     *         If target < current: withdraw sUSDat, convert to USDC, repay
     */
    function _rebalanceLeverage(uint256 targetLev) internal {
        uint256 equity = seniorNAV + juniorNAV;
        if (equity == 0) return;

        uint256 targetCollateral = _mulWad(equity, targetLev);
        uint256 currentCollateral = lendingAdapter.collateralBalance();

        uint256 oldLev = currentLeverage;

        if (targetCollateral > currentCollateral) {
            // Need to lever UP: borrow more USDC, convert to sUSDat, deposit
            uint256 additionalCollateral = targetCollateral - currentCollateral;
            uint256 usdcNeeded = additionalCollateral; // 1:1 simplified (sUSDat ≈ $1)

            // Check we can borrow this much
            uint256 maxBorrowable = lendingAdapter.maxBorrow();
            if (usdcNeeded > maxBorrowable) {
                usdcNeeded = maxBorrowable;
            }

            if (usdcNeeded > 0) {
                lendingAdapter.borrow(usdcNeeded);
                uint256 susdatGot = _usdcToSUsdat(usdcNeeded);
                IERC20(address(sUsdat)).forceApprove(address(lendingAdapter), susdatGot);
                lendingAdapter.depositCollateral(susdatGot);
            }
        } else if (currentCollateral > targetCollateral) {
            // Need to DELEVERAGE: withdraw sUSDat, convert to USDC, repay
            uint256 excessCollateral = currentCollateral - targetCollateral;
            _deleverageAmount(excessCollateral);
        }

        emit LeverageAdjusted(oldLev, targetLev, lendingAdapter.collateralBalance(), lendingAdapter.debtBalance());
    }

    /**
     * @dev Deleverage by withdrawing collateral and repaying debt.
     */
    function _deleverageAmount(uint256 susdatAmount) internal {
        if (susdatAmount == 0) return;

        lendingAdapter.withdrawCollateral(susdatAmount);
        uint256 usdcReceived = _susdatToUsdc(susdatAmount);

        uint256 debt = lendingAdapter.debtBalance();
        uint256 repayAmount = usdcReceived > debt ? debt : usdcReceived;

        if (repayAmount > 0) {
            usdc.forceApprove(address(lendingAdapter), repayAmount);
            lendingAdapter.repay(repayAmount);
        }

        // Any excess USDC goes to reserve
        uint256 excess = usdcReceived > repayAmount ? usdcReceived - repayAmount : 0;
        if (excess > 0) {
            usdcReserve += excess;
        }
    }

    /**
     * @dev Unwind leverage to free USDC for withdrawal.
     *      At 1.75x leverage, freeing $1 requires unwinding ~$1.75 of collateral.
     */
    function _unwindForWithdrawal(uint256 usdcNeeded) internal returns (uint256 usdcFreed) {
        // Need to unwind proportionally more collateral due to leverage
        uint256 unwindAmount = _mulWad(usdcNeeded, currentLeverage);

        uint256 collateral = lendingAdapter.collateralBalance();
        if (unwindAmount > collateral) {
            unwindAmount = collateral;
        }

        if (unwindAmount > 0) {
            lendingAdapter.withdrawCollateral(unwindAmount);
            usdcFreed = _susdatToUsdc(unwindAmount);

            // Repay proportional debt
            uint256 debtPortion = _mulWad(usdcFreed, currentLeverage - WAD) / currentLeverage;
            uint256 debt = lendingAdapter.debtBalance();
            uint256 repay = debtPortion > debt ? debt : debtPortion;

            if (repay > 0) {
                usdc.forceApprove(address(lendingAdapter), repay);
                lendingAdapter.repay(repay);
            }

            usdcFreed = usdcFreed > repay ? usdcFreed - repay : 0;
        }
    }

    // ================================================================
    // USDC ↔ sUSDat CONVERSION
    // ================================================================

    /**
     * @dev Convert USDC to sUSDat via Curve pool (USDC → USDat → sUSDat).
     *      In production, may route through Saturn deposit or Curve depending on rates.
     */
    function _usdcToSUsdat(uint256 usdcAmount) internal returns (uint256 susdatAmount) {
        // Approve Curve pool
        usdc.forceApprove(address(curvePool), usdcAmount);
        // Swap USDC → sUSDat via Curve (indices depend on pool config)
        // Using 1% slippage tolerance
        uint256 minOut = usdcAmount * 99 / 100;
        susdatAmount = curvePool.exchange(0, 1, usdcAmount, minOut);
    }

    /**
     * @dev Convert sUSDat to USDC via Curve pool.
     */
    function _susdatToUsdc(uint256 susdatAmount) internal returns (uint256 usdcAmount) {
        IERC20(address(sUsdat)).forceApprove(address(curvePool), susdatAmount);
        uint256 minOut = susdatAmount * 99 / 100;
        usdcAmount = curvePool.exchange(1, 0, susdatAmount, minOut);
    }

    // ================================================================
    // HEALTH FACTOR MONITORING (Section 9.5)
    // ================================================================

    /**
     * @notice Check health factor and trigger deleveraging cascade if needed.
     * @dev    Can be called by keeper every 30 seconds (not just at epoch).
     *         Four-tier cascade:
     *           HF ≥ 1.8: normal
     *           1.6 ≤ HF < 1.8: freeze leverage increases
     *           1.3 ≤ HF < 1.6: deleverage toward 1.25x
     *           HF < 1.3: accelerated deleverage
     *           HF < 1.1: emergency shutdown
     */
    function checkHealthFactor() external onlyRole(KEEPER_ROLE) {
        uint256 hf = lendingAdapter.healthFactor();

        if (hf < HF_EMERGENCY) {
            // Tier 5: Emergency — deleverage THEN shut down (Fix 2)
            _emergencyDeleverage(WAD); // repay all debt first
            _convertRemainingToUsdc();  // convert sUSDat collateral to USDC
            isShutdown = true;
            _pause();
            emit EmergencyShutdown(block.timestamp);
            return;
        }

        if (hf < HF_ACCELERATE) {
            _emergencyDeleverage(WAD);
            emit EmergencyDeleveraged(hf, WAD);
            return;
        }

        if (hf < HF_DELEVERAGE) {
            if (currentLeverage > LEV_MIN) {
                uint256 targetLev = LEV_MIN;
                _rebalanceLeverage(targetLev);
                currentLeverage = targetLev;
                emit EmergencyDeleveraged(hf, targetLev);
            }
            return;
        }
    }

    /**
     * @dev Emergency deleverage to target leverage. Unwinds as much as possible.
     */
    function _emergencyDeleverage(uint256 targetLev) internal {
        uint256 equity = seniorNAV + juniorNAV;
        if (equity == 0) return;

        uint256 targetCollateral = _mulWad(equity, targetLev);
        uint256 currentCollateral = lendingAdapter.collateralBalance();

        if (currentCollateral > targetCollateral) {
            _deleverageAmount(currentCollateral - targetCollateral);
            currentLeverage = targetLev;
        }
    }

    /**
     * @dev Convert any remaining sUSDat collateral in adapter to USDC.
     *      Called during emergency shutdown so emergencyClaim can distribute real USDC.
     *      Fix 2: Ensures assets are actually claimable after shutdown.
     */
    function _convertRemainingToUsdc() internal {
        // Withdraw any remaining collateral from adapter
        uint256 remaining = lendingAdapter.collateralBalance();
        if (remaining > 0) {
            lendingAdapter.withdrawCollateral(remaining);
            // Convert sUSDat to USDC via Curve
            uint256 usdcReceived = _susdatToUsdc(remaining);
            usdcReserve += usdcReceived;
        }
        currentLeverage = WAD; // 1.0x, no position
    }

    // ================================================================
    // DUAL ORACLE SAFETY (Section 9.7)
    // ================================================================

    /**
     * @dev Check Saturn internal exchange rate vs Curve TWAP.
     *      If they diverge by >2%, trigger circuit breaker.
     */
    function _checkOracleDeviation() internal {
        // Saturn price: sUSDat → USDat conversion rate
        uint256 saturnPrice = sUsdat.convertToAssets(WAD); // 1 sUSDat in USDat terms

        // Curve TWAP price
        uint256 curvePrice = curvePool.price_oracle();

        // Check deviation
        uint256 higher = saturnPrice > curvePrice ? saturnPrice : curvePrice;
        uint256 lower = saturnPrice > curvePrice ? curvePrice : saturnPrice;

        if (higher > 0) {
            uint256 deviation = Math.mulDiv(higher - lower, WAD, higher);
            if (deviation > ORACLE_DEVIATION_MAX) {
                oracleCircuitBroken = true;
                emit OracleCircuitBroken(saturnPrice, curvePrice);
            } else {
                if (oracleCircuitBroken) {
                    oracleCircuitBroken = false;
                    // I2: oracle recovered — emit for monitoring
                }
            }
        }
    }

    // ================================================================
    // EPOCH SETTLEMENT (Section 9 — full integration)
    // ================================================================

    /**
     * @notice Settle one epoch. Full pipeline:
     *         1. Dual oracle safety check
     *         2. Fixed leverage target → leverage target
     *         3. Borrow cost circuit breaker
     *         4. Health factor check
     *         5. Rebalance leverage (actual on-chain position)
     *         6. Execute waterfall (NAV updates)
     *         7. Process withdrawal queue
     *         8. Replenish reserve
     */
    function settleEpoch(SignalData calldata signals) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (isShutdown) revert VaultShutdown();
        if (block.timestamp < lastEpochTimestamp + EPOCH_SECONDS - 1 hours) revert EpochTooSoon();

        // --- 1. Dual oracle check ---
        _checkOracleDeviation();
        bool canAdjustLeverage = !oracleCircuitBroken;

        // --- 2. Fixed leverage target ---
        uint256 newLeverage = TARGET_LEVERAGE;

        // --- 3. Borrow cost circuit breaker ---
        uint256 borrowRate = signals.borrowRate > 0 ? signals.borrowRate : DEFAULT_BORROW;
        if (borrowRate >= BORROW_EMERGENCY) {
            newLeverage = WAD;
            canAdjustLeverage = true;
        } else if (borrowRate >= BORROW_DELEVERAGE) {
            if (newLeverage > WAD) {
                newLeverage = WAD + _mulWad(newLeverage - WAD, 0.5e18);
            }
        } else if (borrowRate >= BORROW_FREEZE) {
            if (newLeverage > currentLeverage) {
                newLeverage = currentLeverage;
            }
        }

        // --- 4. Health factor cascade (Section 7.2) ---
        uint256 hf = lendingAdapter.healthFactor();
        if (hf < HF_EMERGENCY) {
            newLeverage = WAD;
            canAdjustLeverage = true;
        } else if (hf < HF_ACCELERATE) {
            uint256 excess = currentLeverage > WAD ? currentLeverage - WAD : 0;
            newLeverage = currentLeverage - _mulWad(excess, 0.60e18);
            canAdjustLeverage = true;
        } else if (hf < HF_DELEVERAGE) {
            uint256 floor = 1.25e18;
            uint256 excess = currentLeverage > floor ? currentLeverage - floor : 0;
            newLeverage = currentLeverage - _mulWad(excess, 0.30e18);
            canAdjustLeverage = true;
        } else if (hf < HF_FREEZE) {
            if (newLeverage > currentLeverage) {
                newLeverage = currentLeverage;
            }
        }
        // Re-leverage cap after cascade
        if (newLeverage > currentLeverage + LEV_RELEV_CAP) {
            newLeverage = currentLeverage + LEV_RELEV_CAP;
        }
        if (newLeverage > LEV_MAX) newLeverage = LEV_MAX;
        if (newLeverage < WAD) newLeverage = WAD;

        // --- 5. Bunker mode override ---
        if (bunkerMode && newLeverage > WAD) {
            newLeverage = WAD;
        }

        // --- 6. Rebalance actual lending position ---
        if (canAdjustLeverage && newLeverage != currentLeverage) {
            _rebalanceLeverage(newLeverage);
        }

        // A4 FIX: Compute actual leverage from real adapter position, not target
        uint256 equity = seniorNAV + juniorNAV;
        uint256 actualLeverage = newLeverage; // default to target
        if (equity > 0) {
            uint256 actualCollateral = lendingAdapter.collateralBalance();
            if (actualCollateral > 0) {
                actualLeverage = Math.mulDiv(actualCollateral, WAD, equity);
                // Clamp to valid range
                if (actualLeverage > LEV_MAX) actualLeverage = LEV_MAX;
                if (actualLeverage < WAD) actualLeverage = WAD; // can't be below 1.0x
            }
        }

        // --- 7. STRC return for MTM ---
        // A3 FIX: Validate keeper-supplied STRC price against on-chain oracle
        {
            (uint256 oraclePrice, ) = strcOracle.getPrice(); // 8 decimals
            uint256 deviation;
            if (signals.strcPrice > oraclePrice) {
                deviation = Math.mulDiv(signals.strcPrice - oraclePrice, WAD, oraclePrice);
            } else {
                deviation = Math.mulDiv(oraclePrice - signals.strcPrice, WAD, oraclePrice);
            }
            // Allow 1% deviation between keeper price and oracle (latency tolerance)
            require(deviation <= 0.01e18, "STRC price mismatch vs oracle");
        }

        int256 strcReturn = 0;
        if (signals.prevStrcPrice > 0) {
            strcReturn = (int256(signals.strcPrice) - int256(signals.prevStrcPrice))
                * int256(WAD) / int256(signals.prevStrcPrice);
        }

        // --- 8. Execute waterfall (using actual leverage, not target) ---
        WaterfallResult memory wf = _executeWaterfall(
            seniorNAV, juniorNAV, actualLeverage, strcReturn, borrowRate
        );

        // --- 9. Update state ---
        uint256 newSeniorNAV = seniorNAV + wf.seniorCoupon;
        if (newSeniorNAV > wf.seniorMgmtFee) {
            newSeniorNAV -= wf.seniorMgmtFee;
        } else {
            newSeniorNAV = 0;
        }
        if (wf.seniorImpairment > 0 && newSeniorNAV > wf.seniorImpairment) {
            newSeniorNAV -= wf.seniorImpairment;
        } else if (wf.seniorImpairment > 0) {
            newSeniorNAV = 0;
        }

        uint256 newJuniorNAV;
        if (wf.juniorNetDelta >= 0) {
            newJuniorNAV = juniorNAV + uint256(wf.juniorNetDelta);
        } else {
            uint256 loss = uint256(-wf.juniorNetDelta);
            newJuniorNAV = juniorNAV > loss ? juniorNAV - loss : 0;
        }

        seniorNAV = newSeniorNAV;
        juniorNAV = newJuniorNAV;
        currentLeverage = actualLeverage;
        currentEpoch++;
        lastEpochTimestamp = block.timestamp;

        accruedFees += wf.seniorMgmtFee + wf.juniorMgmtFee + wf.perfFee;

        // --- 10. Process pending deposits (async ERC-7540 pattern) ---
        _processDeposits();

        // --- 11. Process withdrawals ---
        _processWithdrawals();

        // --- 12. Replenish reserve ---
        _replenishReserve();

        // --- 13. Fix 3: Recompute actual leverage after all operations ---
        // Withdrawals and reserve replenishment may have changed adapter state
        uint256 finalEquity = seniorNAV + juniorNAV;
        if (finalEquity > 0) {
            uint256 finalCollateral = lendingAdapter.collateralBalance();
            if (finalCollateral > 0) {
                currentLeverage = Math.mulDiv(finalCollateral, WAD, finalEquity);
                if (currentLeverage > LEV_MAX) currentLeverage = LEV_MAX;
                if (currentLeverage < WAD) currentLeverage = WAD;
            } else {
                currentLeverage = WAD;
            }
        }

        emit EpochSettled(currentEpoch, seniorNAV, juniorNAV, currentLeverage, hf);
        emit WaterfallExecuted(currentEpoch, wf);
    }

    /**
     * @dev Replenish USDC reserve toward target (7.5% of TVL).
     *      Pulls from lending position if reserve is below target.
     */
    function _replenishReserve() internal {
        uint256 totalTVL = seniorNAV + juniorNAV;
        if (totalTVL == 0) return;

        uint256 target = _mulWad(totalTVL, RESERVE_TARGET);
        if (usdcReserve >= target) return;

        // L6 FIX: Don't pull collateral if HF is already stressed
        uint256 hf = lendingAdapter.healthFactor();
        if (hf < HF_FREEZE) return;

        uint256 deficit = target - usdcReserve;
        // Don't pull more than 2% of TVL per epoch to avoid disruption
        uint256 maxPull = _mulWad(totalTVL, 0.02e18);
        uint256 pull = deficit > maxPull ? maxPull : deficit;

        if (pull > 0 && lendingAdapter.collateralBalance() > pull) {
            _deleverageAmount(pull);
        }
        // M6: Log if reserve remains below target after replenish attempt
    }

    // ================================================================
    // LEVERAGE (Section 7) — Fixed 1.75x + HF Cascade
    // ================================================================
    // No signal-based leverage adjustment. HF cascade in settleEpoch()
    // provides tail-risk protection.

    // ================================================================
    // YIELD WATERFALL (Section 9.6)
    // ================================================================

    function _executeWaterfall(
        uint256 srNAV, uint256 jrNAV, uint256 leverage,
        int256 strcReturn, uint256 borrowRate
    ) internal pure returns (WaterfallResult memory wf) {
        uint256 totalPool = srNAV + jrNAV;
        if (totalPool == 0) return wf;

        uint256 weeklyYield = SUSDAT_YIELD / EPOCHS_PER_YEAR;
        uint256 weeklyBorrow = borrowRate / EPOCHS_PER_YEAR;
        uint256 levMinusOne = leverage > WAD ? leverage - WAD : 0;

        // A2 FIX: Allow negative pool income (negative carry)
        uint256 grossYield = _mulWad(leverage, weeklyYield);
        uint256 borrowCost = _mulWad(levMinusOne, weeklyBorrow);
        int256 poolYieldSigned;
        if (grossYield >= borrowCost) {
            wf.poolIncome = _mulWad(totalPool, grossYield - borrowCost);
            poolYieldSigned = int256(wf.poolIncome);
        } else {
            // Negative carry: borrow cost exceeds yield
            uint256 negativeCarry = _mulWad(totalPool, borrowCost - grossYield);
            wf.poolIncome = 0;
            poolYieldSigned = -int256(negativeCarry);
        }

        if (strcReturn >= 0) {
            uint256 mtm = Math.mulDiv(totalPool, uint256(strcReturn), WAD);
            wf.poolMTM = int256(Math.mulDiv(mtm, leverage, WAD));
        } else {
            uint256 mtm = Math.mulDiv(totalPool, uint256(-strcReturn), WAD);
            wf.poolMTM = -int256(Math.mulDiv(mtm, leverage, WAD));
        }

        // A1 FIX: Senior coupon capped at available pool income
        uint256 maxSeniorCoupon = Math.mulDiv(srNAV, SR_GROSS_APY, EPOCHS_PER_YEAR * WAD);
        wf.seniorMgmtFee = Math.mulDiv(srNAV, SR_MGMT_FEE, EPOCHS_PER_YEAR * WAD);

        if (poolYieldSigned > 0) {
            // Positive income: senior gets min(target coupon, available income)
            uint256 available = uint256(poolYieldSigned);
            wf.seniorCoupon = maxSeniorCoupon > available ? available : maxSeniorCoupon;
            // If income doesn't even cover mgmt fee, reduce it
            if (wf.seniorCoupon + wf.seniorMgmtFee > available) {
                wf.seniorMgmtFee = available > wf.seniorCoupon ? available - wf.seniorCoupon : 0;
            }
        } else {
            // Negative carry: no senior coupon, no fees — junior absorbs loss
            wf.seniorCoupon = 0;
            wf.seniorMgmtFee = 0;
        }

        uint256 seniorCosts = wf.seniorCoupon + wf.seniorMgmtFee;

        // Junior: residual income (if any) after senior claim
        uint256 jrGrossYield = 0;
        if (poolYieldSigned > 0 && uint256(poolYieldSigned) > seniorCosts) {
            jrGrossYield = uint256(poolYieldSigned) - seniorCosts;
        }

        wf.perfFee = jrGrossYield > 0 ? Math.mulDiv(jrGrossYield, JR_PERF_FEE, WAD) : 0;
        wf.juniorMgmtFee = Math.mulDiv(jrNAV, JR_MGMT_FEE, EPOCHS_PER_YEAR * WAD);

        // Junior net delta = income residual - fees + MTM + negative carry (if any)
        int256 jrYieldNet = int256(jrGrossYield) - int256(wf.perfFee) - int256(wf.juniorMgmtFee);
        // If negative carry, junior absorbs it
        if (poolYieldSigned < 0) {
            jrYieldNet += poolYieldSigned; // subtracts the negative carry
        }
        wf.juniorNetDelta = jrYieldNet + wf.poolMTM;

        int256 projectedJrNAV = int256(jrNAV) + wf.juniorNetDelta;
        if (projectedJrNAV < 0) {
            wf.seniorImpairment = uint256(-projectedJrNAV);
            wf.juniorNetDelta = -int256(jrNAV);
        }
    }

    // ================================================================
    // RATIO, SHARES, TVL HELPERS
    // ================================================================

    function _checkTVLCap(uint256 depositAmount) internal view {
        if (tvlCap > 0) {
            uint256 newTVL = seniorNAV + juniorNAV + depositAmount;
            if (newTVL > tvlCap) revert TVLCapExceeded();
        }
    }

    /// @dev Fix 4: Include pending deposits in TVL cap check
    function _checkTVLCapWithPending(uint256 depositAmount) internal view {
        if (tvlCap > 0) {
            uint256 newTVL = seniorNAV + juniorNAV + pendingDeposits + depositAmount;
            if (newTVL > tvlCap) revert TVLCapExceeded();
        }
    }

    /// @dev Fix 4: Include pending deposits in ratio check
    function _wouldBreakRatioWithPending(uint256 depositAmount, bool isSenior) internal view returns (bool) {
        uint256 newSr = seniorNAV + pendingSeniorDeposits + (isSenior ? depositAmount : 0);
        uint256 newJr = juniorNAV + pendingJuniorDeposits + (isSenior ? 0 : depositAmount);
        uint256 total = newSr + newJr;
        if (total == 0) return false;
        if (seniorNAV == 0 || juniorNAV == 0) return false;
        uint256 ratio = Math.mulDiv(newSr, WAD, total);
        return ratio < RATIO_MIN || ratio > RATIO_MAX;
    }

    function _calculateShares(uint256 assets, uint256 nav, uint256 totalSupply)
        internal pure returns (uint256)
    {
        if (totalSupply == 0 || nav == 0) {
            return assets * 1e12;
        }
        return Math.mulDiv(assets, totalSupply, nav);
    }

    function _sharesToAssets(uint256 shares, uint256 nav, uint256 totalSupply)
        internal pure returns (uint256)
    {
        if (totalSupply == 0) return 0;
        return Math.mulDiv(shares, nav, totalSupply);
    }

    // ================================================================
    // VIEW FUNCTIONS
    // ================================================================

    function currentRatio() external view returns (uint256) {
        uint256 total = seniorNAV + juniorNAV;
        if (total == 0) return RATIO_TARGET;
        return Math.mulDiv(seniorNAV, WAD, total);
    }

    function tvl() external view returns (uint256) {
        return seniorNAV + juniorNAV;
    }

    function seniorSharePrice() external view returns (uint256) {
        uint256 supply = sdcSenior.totalSupply();
        if (supply == 0) return USDC_DECIMALS;
        return Math.mulDiv(seniorNAV, 1e18, supply);
    }

    function juniorSharePrice() external view returns (uint256) {
        uint256 supply = sdcJunior.totalSupply();
        if (supply == 0) return USDC_DECIMALS;
        return Math.mulDiv(juniorNAV, 1e18, supply);
    }

    function canSettle() external view returns (bool) {
        return block.timestamp >= lastEpochTimestamp + EPOCH_SECONDS - 1 hours;
    }

    /// @notice Get on-chain health factor from lending adapter
    function getHealthFactor() external view returns (uint256) {
        return lendingAdapter.healthFactor();
    }

    /// @notice Get current borrow rate from lending adapter
    function getBorrowRate() external view returns (uint256) {
        return lendingAdapter.currentBorrowRate();
    }

    /// @notice Get position details from lending adapter
    function getPosition() external view returns (uint256 collateral, uint256 debt, uint256 hf) {
        collateral = lendingAdapter.collateralBalance();
        debt = lendingAdapter.debtBalance();
        hf = lendingAdapter.healthFactor();
    }

    // ================================================================
    // ADMIN / GOVERNANCE
    // ================================================================

    function emergencyShutdown() external onlyRole(GUARDIAN_ROLE) {
        isShutdown = true;
        _pause();
        // Fix 2: Full unwind — deleverage then convert all sUSDat to USDC
        _emergencyDeleverage(WAD);
        _convertRemainingToUsdc();
        emit EmergencyShutdown(block.timestamp);
    }

    /**
     * @notice Claim pro-rata share of vault assets after emergency shutdown.
     * @dev    Senior paid first up to principal + accrued yield. Junior gets residual.
     *         Users burn their tranche tokens to claim USDC.
     * @param isSenior True to claim from senior, false for junior
     */
    function emergencyClaim(bool isSenior) external nonReentrant {
        if (!isShutdown) revert NotShutdown();

        // H3 FIX: Junior cannot claim until all senior shares burned,
        // OR 30 days after shutdown (L2: prevent permanent junior lockout)
        if (!isSenior) {
            require(
                sdcSenior.totalSupply() == 0 || block.timestamp >= lastEpochTimestamp + 30 days,
                "senior claims first"
            );
        }

        TrancheToken token = isSenior ? sdcSenior : sdcJunior;
        uint256 userShares = token.balanceOf(msg.sender);
        if (userShares == 0) revert ZeroAmount();

        uint256 supply = token.totalSupply();
        uint256 nav = isSenior ? seniorNAV : juniorNAV;

        // Pro-rata: user gets (userShares / totalSupply) × tranche NAV
        uint256 usdcOwed = Math.mulDiv(userShares, nav, supply);

        // Cap at available USDC
        uint256 available = usdc.balanceOf(address(this));
        if (usdcOwed > available) usdcOwed = available;

        // Burn shares
        token.burn(msg.sender, userShares);

        // Update NAV
        if (isSenior) {
            seniorNAV = seniorNAV > usdcOwed ? seniorNAV - usdcOwed : 0;
        } else {
            juniorNAV = juniorNAV > usdcOwed ? juniorNAV - usdcOwed : 0;
        }

        // Transfer USDC
        if (usdcOwed > 0) {
            usdc.safeTransfer(msg.sender, usdcOwed);
        }

        emit EmergencyClaim(msg.sender, isSenior, usdcOwed);
    }

    function withdrawFees(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 fees = accruedFees;
        // Fix 5b: Don't allow fee withdrawal to consume reserve or pending deposits
        uint256 available = usdc.balanceOf(address(this));
        uint256 protected = usdcReserve + pendingDeposits;
        uint256 withdrawable = available > protected ? available - protected : 0;
        uint256 payout = fees > withdrawable ? withdrawable : fees;
        accruedFees = fees - payout;
        if (payout > 0) {
            usdc.safeTransfer(to, payout);
        }
    }

    function pause() external onlyRole(GUARDIAN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    /// @notice Set TVL cap (0 = no cap). Admin only, for phased launch.
    function setTVLCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tvlCap = cap;
    }

    /// @notice Queue a timelocked update to lending adapter. 7-day delay (Section 9.10).
    function queueSetLendingAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 id) {
        require(adapter != address(0), "zero addr");
        id = nextTimelockId++;
        bytes32 hash = keccak256(abi.encode("setLendingAdapter", adapter));
        timelockRequests[id] = TimelockRequest(hash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockQueued(id, hash, block.timestamp + TIMELOCK_DELAY);
    }

    /// @notice Execute a timelocked lending adapter update after delay has passed.
    function executeSetLendingAdapter(uint256 id, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TimelockRequest storage req = timelockRequests[id];
        require(!req.executed, "already executed");
        require(block.timestamp >= req.executeAfter, "timelock not elapsed");
        require(req.actionHash == keccak256(abi.encode("setLendingAdapter", adapter)), "hash mismatch");
        req.executed = true;
        lendingAdapter = ILendingAdapter(adapter);
        emit TimelockExecuted(id);
    }

    /// @notice Queue a timelocked update to Curve pool. 7-day delay.
    function queueSetCurvePool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 id) {
        require(pool != address(0), "zero addr");
        id = nextTimelockId++;
        bytes32 hash = keccak256(abi.encode("setCurvePool", pool));
        timelockRequests[id] = TimelockRequest(hash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockQueued(id, hash, block.timestamp + TIMELOCK_DELAY);
    }

    /// @notice Execute a timelocked Curve pool update after delay has passed.
    function executeSetCurvePool(uint256 id, address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TimelockRequest storage req = timelockRequests[id];
        require(!req.executed, "already executed");
        require(block.timestamp >= req.executeAfter, "timelock not elapsed");
        require(req.actionHash == keccak256(abi.encode("setCurvePool", pool)), "hash mismatch");
        req.executed = true;
        curvePool = ICurvePool(pool);
        emit TimelockExecuted(id);
    }

    // ================================================================
    // INTERNAL MATH
    // ================================================================

    function _mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, WAD);
    }
}
