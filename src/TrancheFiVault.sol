// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IStakedUSDat, IUnderlyingPriceOracle} from "./interfaces/IVaultUnderlying.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {TrancheToken} from "./tokens/TrancheToken.sol";

/**
 * @title  TrancheFiVault
 * @author TrancheFi
 * @notice Two-tranche structured credit vault applying CLO waterfall mechanics
 *         to leveraged digital credit instruments (sUSDat, apyUSD, etc.).
 *
 * @dev    Architecture (Whitepaper v7.5):
 *           - Fixed 1.75x leverage via Morpho lending adapter
 *           - Epoch-based async settlement (ERC-7540 pattern)
 *           - Waterfall: senior 8% fixed first, junior absorbs residual + all MTM
 *           - Underlying yield derived from exchange rate delta each epoch (no hardcoded APY)
 *           - Coverage-based deposit/withdrawal gates (replaces ratio band)
 *           - Multi-tier HF cascade for tail-risk protection
 *           - Governance-adjustable fees with hardcoded max ceilings
 *           - Dual oracle safety (internal exchange rate + Curve TWAP)
 */
contract TrancheFiVault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ================================================================
    // WAD AND DECIMALS
    // ================================================================

    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_DECIMALS = 1e6;

    // ================================================================
    // ROLES
    // ================================================================

    bytes32 public constant KEEPER_ROLE   = keccak256("KEEPER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ================================================================
    // SENIOR TRANCHE — CONSTANTS (product promise, not governance)
    // ================================================================

    uint256 public constant SR_GROSS_APY = 0.085e18;  // 8.5% gross target
    uint256 public constant SR_NET_APY   = 0.080e18;  // 8.0% net (used for live accrual)

    // ================================================================
    // FEE PARAMETERS — governance-adjustable, hardcoded ceilings
    // ================================================================

    /// @notice Hard ceiling on management fee — can never be exceeded
    uint256 public constant MAX_MGMT_FEE = 0.02e18;   // 2% absolute max
    /// @notice Hard ceiling on performance fee — can never be exceeded
    uint256 public constant MAX_PERF_FEE = 0.20e18;   // 20% absolute max

    /// @notice Current senior management fee (launch: 0%)
    uint256 public srMgmtFee = 0;
    /// @notice Current junior management fee (launch: 0%)
    uint256 public jrMgmtFee = 0;
    /// @notice Current junior performance fee on yield income only (launch: 10%)
    uint256 public jrPerfFee = 0.10e18;

    // ================================================================
    // YIELD — epoch-0 fallback only; real yield derived from exchange rate
    // ================================================================

    /// @notice Used ONLY for epoch 0 when lastExchangeRate is unset.
    ///         From epoch 1 onward, yield is derived from sUsdat.convertToAssets() delta.
    uint256 public constant SUSDAT_YIELD_FALLBACK = 0.1035e18;

    /// @notice Default borrow rate fallback if adapter returns zero
    uint256 public constant DEFAULT_BORROW = 0.07e18;

    // ================================================================
    // LEVERAGE
    // ================================================================

    uint256 public constant TARGET_LEVERAGE = 1.75e18;
    uint256 public constant LEV_MIN         = 1.00e18;
    uint256 public constant LEV_MAX         = 2.00e18;
    uint256 public constant LEV_RELEV_CAP   = 0.25e18;  // max re-leverage per epoch

    // ================================================================
    // COVERAGE FLOOR GATES (replaces ratio band)
    // ================================================================

    /// @notice Leverage-adjusted coverage = juniorNAV / (totalNAV * currentLeverage)
    /// @notice Below SOFT_FLOOR: junior withdrawals capped at 10% per epoch; senior deposits blocked
    uint256 public constant COVERAGE_SOFT_FLOOR = 0.15e18;  // 15%
    /// @notice Below HARD_FLOOR: junior withdrawals fully paused; senior deposits blocked
    uint256 public constant COVERAGE_HARD_FLOOR = 0.12e18;  // 12%
    /// @notice Above RECOVERY: all restrictions lift automatically
    uint256 public constant COVERAGE_RECOVERY   = 0.18e18;  // 18%

    // ================================================================
    // HEALTH FACTOR CASCADE
    // ================================================================

    uint256 public constant HF_TARGET     = 2.00e18;
    uint256 public constant HF_FREEZE     = 1.80e18;  // freeze leverage increases
    uint256 public constant HF_DELEVERAGE = 1.60e18;  // begin deleveraging
    uint256 public constant HF_ACCELERATE = 1.30e18;  // accelerated deleveraging
    uint256 public constant HF_EMERGENCY  = 1.10e18;  // emergency shutdown

    // ================================================================
    // WITHDRAWAL GATES
    // ================================================================

    uint256 public constant WITHDRAWAL_CAP    = 0.15e18;  // normal epoch cap
    uint256 public constant WITHDRAWAL_STRESSED = 0.10e18; // cap under coverage stress
    uint256 public constant BUNKER_THRESHOLD  = 0.25e18;  // bunker mode trigger
    uint256 public constant BUNKER_CAP        = 0.10e18;  // cap in bunker mode

    // ================================================================
    // RESERVE
    // ================================================================

    uint256 public constant RESERVE_TARGET = 0.075e18;  // 7.5% of TVL

    // ================================================================
    // BORROW COST CIRCUIT BREAKER
    // ================================================================

    uint256 public constant BORROW_FREEZE      = 0.10e18;  // 10%: freeze leverage increases
    uint256 public constant BORROW_DELEVERAGE  = 0.12e18;  // 12%: begin deleveraging
    uint256 public constant BORROW_EMERGENCY   = 0.15e18;  // 15%: deleverage to 1.0x

    // ================================================================
    // ORACLE
    // ================================================================

    uint256 public constant ORACLE_DEVIATION_MAX = 0.02e18;  // 2% max divergence

    // ================================================================
    // MISC
    // ================================================================

    uint256 public constant MIN_DEPOSIT    = 100e6;  // $100 minimum (inflation attack prevention)
    uint256 public constant EPOCH_SECONDS  = 7 days;
    uint256 public constant EPOCHS_PER_YEAR = 52;
    uint256 public constant TIMELOCK_DELAY = 7 days;

    // ================================================================
    // EXTERNAL CONTRACTS
    // ================================================================

    IERC20 public immutable usdc;
    IERC20 public immutable underlyingToken;      // sUSDat or apyUSD
    IStakedUSDat public immutable stakedUnderlying; // for convertToAssets() yield derivation
    IUnderlyingPriceOracle public immutable underlyingOracle; // for MTM price validation

    ILendingAdapter public lendingAdapter;
    ICurvePool public curvePool;

    // ================================================================
    // TRANCHE TOKENS
    // ================================================================

    TrancheToken public immutable sdcSenior;
    TrancheToken public immutable sdcJunior;

    // ================================================================
    // TIMELOCK
    // ================================================================

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
    bool    public isShutdown;
    uint256 public shutdownTimestamp;

    /// @notice Exchange rate stored from last epoch settlement (for yield derivation)
    uint256 public lastExchangeRate;

    /// @notice Underlying asset price stored from last epoch settlement (for MTM validation)
    uint256 public lastSettledUnderlyingPrice;

    // ================================================================
    // RESERVE + BUNKER
    // ================================================================

    uint256 public usdcReserve;
    bool    public bunkerMode;

    // ================================================================
    // TVL CAP
    // ================================================================

    uint256 public tvlCap;

    // ================================================================
    // ORACLE STATE
    // ================================================================

    bool public oracleCircuitBroken;

    // ================================================================
    // WITHDRAWAL QUEUE
    // ================================================================

    struct WithdrawalRequest {
        address user;
        bool    isSenior;
        uint256 shares;
        uint256 epoch;
        bool    fulfilled;
        uint256 usdcAmount;
    }

    uint256 public nextRequestId;
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    uint256 public queuedSeniorShares;
    uint256 public queuedJuniorShares;

    // ================================================================
    // DEPOSIT QUEUE — Async ERC-7540
    // ================================================================

    struct DepositRequest {
        address user;
        bool    isSenior;
        uint256 assets;
        uint256 epoch;
        bool    processed;
        uint256 shares;
    }

    uint256 public nextDepositRequestId;
    mapping(uint256 => DepositRequest) public depositRequests;

    uint256 public pendingDeposits;
    uint256 public pendingSeniorDeposits;
    uint256 public pendingJuniorDeposits;

    uint256 public lastProcessedDepositId;
    uint256 public lastProcessedSeniorWithdrawalId;
    uint256 public lastProcessedJuniorWithdrawalId;
    uint256 public constant MAX_WITHDRAWAL_ITERATIONS = 50;

    // ================================================================
    // INSTANT REDEEM TRACKING
    // ================================================================

    uint256 public epochInstantRedeemed;
    uint256 public lastInstantRedeemEpoch;
    mapping(address => uint256) public lastCancelRedeemEpoch;

    // ================================================================
    // STRUCTS
    // ================================================================

    /// @notice Data supplied by keeper at each epoch settlement
    struct SignalData {
        uint256 underlyingPrice;      // current collateral price (8 decimals)
        uint256 prevUnderlyingPrice;  // previous epoch price — validated against stored value
        // borrowRate intentionally excluded: read from lendingAdapter.currentBorrowRate()
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
    event OracleCircuitBroken(uint256 internalPrice, uint256 curvePrice);
    event EmergencyShutdown(uint256 timestamp);
    event EmergencyClaim(address indexed user, bool indexed isSenior, uint256 usdcAmount);
    event EmergencyDeleveraged(uint256 healthFactor, uint256 newLeverage);
    event FeesUpdated(uint256 srMgmtFee, uint256 jrMgmtFee, uint256 jrPerfFee);

    // ================================================================
    // ERRORS
    // ================================================================

    error ZeroAmount();
    error CoverageTooLow();
    error EpochTooSoon();
    error VaultShutdown();
    error NotShutdown();
    error TVLCapExceeded();
    error InsufficientShares();
    error RequestNotFulfilled();
    error RequestAlreadyClaimed();
    error NotRequestOwner();
    error DepositNotProcessed();
    error DepositAlreadyClaimed();

    // ================================================================
    // CONSTRUCTOR
    // ================================================================

    constructor(
        address _usdc,
        address _underlying,
        address _stakedUnderlying,
        address _underlyingOracle,
        address _lendingAdapter,
        address _curvePool,
        address _admin,
        address _keeper
    ) {
        require(_usdc != address(0) && _underlying != address(0), "zero addr");
        require(_stakedUnderlying != address(0) && _underlyingOracle != address(0), "zero addr");

        usdc               = IERC20(_usdc);
        underlyingToken    = IERC20(_underlying);
        stakedUnderlying   = IStakedUSDat(_stakedUnderlying);
        underlyingOracle   = IUnderlyingPriceOracle(_underlyingOracle);
        lendingAdapter     = ILendingAdapter(_lendingAdapter);
        curvePool          = ICurvePool(_curvePool);

        sdcSenior = new TrancheToken("TrancheFi Senior", "sdcSENIOR", address(this));
        sdcJunior = new TrancheToken("TrancheFi Junior", "sdcJUNIOR", address(this));

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
        _grantRole(GUARDIAN_ROLE, _admin);

        currentLeverage    = TARGET_LEVERAGE;
        lastEpochTimestamp = block.timestamp;
    }

    // ================================================================
    // VIEW — COVERAGE
    // ================================================================

    /**
     * @notice Leverage-adjusted junior coverage ratio.
     * @dev    coverage = juniorNAV / (totalNAV * currentLeverage)
     *         This is the true structural metric — not the raw ratio.
     *         At 70/30 and 1.75x: 0.30 / 1.75 = 17.1%.
     * @return coverage Coverage in WAD (1e18 = 100%)
     */
    function getLeverageAdjustedCoverage() public view returns (uint256 coverage) {
        uint256 totalNAV = seniorNAV + juniorNAV;
        if (totalNAV == 0 || currentLeverage == 0) return WAD;
        uint256 scaledTotal = Math.mulDiv(totalNAV, currentLeverage, WAD);
        if (scaledTotal == 0) return WAD;
        coverage = Math.mulDiv(juniorNAV, WAD, scaledTotal);
    }

    // ================================================================
    // DEPOSIT — ASYNC ERC-7540
    // ================================================================

    /**
     * @notice Request deposit. USDC transferred immediately; shares minted at next epoch settlement.
     * @dev    Senior deposits are blocked when coverage < COVERAGE_HARD_FLOOR.
     *         Junior deposits are never blocked — they always improve coverage.
     */
    function requestDeposit(uint256 assets, bool isSenior) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (isShutdown) revert VaultShutdown();
        if (assets == 0) revert ZeroAmount();
        require(assets >= MIN_DEPOSIT, "below minimum deposit");
        _checkTVLCapWithPending(assets);

        // Coverage gate: senior deposits blocked below hard floor
        if (isSenior && seniorNAV > 0 && juniorNAV > 0) {
            if (getLeverageAdjustedCoverage() < COVERAGE_HARD_FLOOR) revert CoverageTooLow();
        }

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        pendingDeposits += assets;
        if (isSenior) {
            pendingSeniorDeposits += assets;
        } else {
            pendingJuniorDeposits += assets;
        }

        requestId = nextDepositRequestId++;
        depositRequests[requestId] = DepositRequest({
            user:      msg.sender,
            isSenior:  isSenior,
            assets:    assets,
            epoch:     currentEpoch,
            processed: false,
            shares:    0
        });

        emit DepositRequested(msg.sender, isSenior, assets, requestId);
    }

    /// @notice Claim shares after epoch settlement has processed the deposit request.
    function claimDeposit(uint256 requestId) external nonReentrant {
        DepositRequest storage req = depositRequests[requestId];
        if (req.user != msg.sender) revert NotRequestOwner();
        if (!req.processed)         revert DepositNotProcessed();
        if (req.shares == 0)        revert DepositAlreadyClaimed();

        uint256 shares = req.shares;
        req.shares = 0;

        TrancheToken token = req.isSenior ? sdcSenior : sdcJunior;
        IERC20(address(token)).safeTransfer(msg.sender, shares);

        emit DepositClaimed(msg.sender, requestId, shares);
    }

    /// @notice Cancel an unprocessed deposit request and reclaim USDC.
    function cancelDeposit(uint256 requestId) external nonReentrant {
        DepositRequest storage req = depositRequests[requestId];
        if (req.user != msg.sender) revert NotRequestOwner();
        require(!req.processed, "already processed");
        require(req.assets > 0,   "already cancelled");

        uint256 assets = req.assets;
        req.assets = 0;

        pendingDeposits -= assets;
        if (req.isSenior) {
            pendingSeniorDeposits = pendingSeniorDeposits > assets ? pendingSeniorDeposits - assets : 0;
        } else {
            pendingJuniorDeposits = pendingJuniorDeposits > assets ? pendingJuniorDeposits - assets : 0;
        }

        usdc.safeTransfer(msg.sender, assets);
    }

    /**
     * @notice Bootstrap synchronous deposit — only callable when a tranche has zero NAV.
     * @dev    Used to seed the vault with initial 70/30 split before public access opens.
     *         Junior should be seeded FIRST to establish subordination before senior deposits.
     */
    function depositSenior(uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (isShutdown) revert VaultShutdown();
        if (assets == 0) revert ZeroAmount();
        require(assets >= MIN_DEPOSIT, "below minimum deposit");
        require(seniorNAV == 0 || juniorNAV == 0, "use requestDeposit after bootstrap");
        _checkTVLCapWithPending(assets);

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        uint256 reservePortion = _mulWad(assets, RESERVE_TARGET);
        usdcReserve += reservePortion;

        shares = _calculateShares(assets, seniorNAV, sdcSenior.totalSupply());
        sdcSenior.mint(msg.sender, shares);
        seniorNAV += assets;

        uint256 deployPortion = assets - reservePortion;
        if (deployPortion > 0) _deployCapital(deployPortion);

        emit Deposited(msg.sender, true, assets, shares);
    }

    function depositJunior(uint256 assets) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (isShutdown) revert VaultShutdown();
        if (assets == 0) revert ZeroAmount();
        require(assets >= MIN_DEPOSIT, "below minimum deposit");
        require(seniorNAV == 0 || juniorNAV == 0, "use requestDeposit after bootstrap");
        _checkTVLCapWithPending(assets);

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        uint256 reservePortion = _mulWad(assets, RESERVE_TARGET);
        usdcReserve += reservePortion;

        shares = _calculateShares(assets, juniorNAV, sdcJunior.totalSupply());
        sdcJunior.mint(msg.sender, shares);
        juniorNAV += assets;

        uint256 deployPortion = assets - reservePortion;
        if (deployPortion > 0) _deployCapital(deployPortion);

        emit Deposited(msg.sender, false, assets, shares);
    }

    // ================================================================
    // WITHDRAWALS
    // ================================================================

    /**
     * @notice Instant withdrawal from USDC reserve. Falls back to queue if reserve/cap insufficient.
     * @dev    Junior instantRedeem checks coverage state before proceeding.
     */
    function instantRedeem(uint256 shares, bool isSenior) external nonReentrant whenNotPaused returns (uint256 usdcOut, bool queued) {
        if (isShutdown) revert VaultShutdown();
        if (shares == 0) revert ZeroAmount();
        require(!bunkerMode, "bunker mode: use requestRedeem");
        require(lastCancelRedeemEpoch[msg.sender] != currentEpoch, "wait for next epoch after cancel");

        // Junior coverage gate for instant redemption
        if (!isSenior) {
            uint256 coverage = getLeverageAdjustedCoverage();
            if (coverage < COVERAGE_HARD_FLOOR) revert CoverageTooLow();
        }

        TrancheToken token = isSenior ? sdcSenior : sdcJunior;
        if (token.balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint256 nav    = isSenior ? _liveSeniorNAV() : _liveJuniorNAV();
        uint256 supply = token.totalSupply();
        if (supply == 0) revert ZeroAmount();
        usdcOut = (shares * nav) / supply;

        // Reset epoch cap counter if new epoch
        if (lastInstantRedeemEpoch != currentEpoch) {
            epochInstantRedeemed    = 0;
            lastInstantRedeemEpoch  = currentEpoch;
        }

        uint256 totalTVL = seniorNAV + juniorNAV;
        uint256 epochCap = _mulWad(totalTVL, WITHDRAWAL_CAP);

        if (epochInstantRedeemed + usdcOut > epochCap || usdcOut > usdcReserve) {
            return _queueWithdrawal(shares, isSenior);
        }

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
        emit WithdrawalClaimed(msg.sender, type(uint256).max, usdcOut);
        return (usdcOut, false);
    }

    /// @notice Queue a withdrawal request for epoch settlement processing.
    function requestRedeem(uint256 shares, bool isSenior) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        TrancheToken token = isSenior ? sdcSenior : sdcJunior;
        if (token.balanceOf(msg.sender) < shares) revert InsufficientShares();

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), shares);
        (requestId, ) = _queueWithdrawal(shares, isSenior);
    }

    /// @dev Internal helper to create a queued withdrawal request.
    function _queueWithdrawal(uint256 shares, bool isSenior) internal returns (uint256 requestId, bool queued) {
        requestId = nextRequestId++;
        withdrawalRequests[requestId] = WithdrawalRequest({
            user:      msg.sender,
            isSenior:  isSenior,
            shares:    shares,
            epoch:     currentEpoch,
            fulfilled: false,
            usdcAmount: 0
        });

        if (isSenior) {
            queuedSeniorShares += shares;
        } else {
            queuedJuniorShares += shares;
        }

        emit WithdrawalRequested(msg.sender, isSenior, shares, requestId);
        return (requestId, true);
    }

    /// @notice Cancel an unfulfilled queued withdrawal. 0.1% cancel fee burned to benefit remaining holders.
    function cancelRedeem(uint256 requestId) external nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        if (req.user != msg.sender) revert NotRequestOwner();
        require(!req.fulfilled, "already fulfilled");
        require(req.shares > 0,  "already cancelled");

        lastCancelRedeemEpoch[msg.sender] = currentEpoch;

        uint256 shares = req.shares;
        req.shares = 0;

        if (req.isSenior) {
            queuedSeniorShares -= shares;
        } else {
            queuedJuniorShares -= shares;
        }

        TrancheToken token = req.isSenior ? sdcSenior : sdcJunior;
        uint256 feeShares    = shares * 10 / 10000;  // 0.1%
        uint256 returnShares = shares - feeShares;

        if (feeShares > 0) token.burn(address(this), feeShares);
        IERC20(address(token)).safeTransfer(msg.sender, returnShares);
    }

    /// @notice Claim USDC after a queued withdrawal has been fulfilled at epoch settlement.
    function claimWithdrawal(uint256 requestId) external nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[requestId];
        if (req.user != msg.sender)  revert NotRequestOwner();
        if (!req.fulfilled)           revert RequestNotFulfilled();
        if (req.usdcAmount == 0)      revert RequestAlreadyClaimed();

        uint256 amount = req.usdcAmount;
        req.usdcAmount = 0;

        usdc.safeTransfer(msg.sender, amount);
        emit WithdrawalClaimed(msg.sender, requestId, amount);
    }

    // ================================================================
    // INTERNAL — PROCESS WITHDRAWALS
    // ================================================================

    function _processWithdrawals() internal {
        uint256 totalTVL = seniorNAV + juniorNAV;
        if (totalTVL == 0) return;

        uint256 capRate = bunkerMode ? BUNKER_CAP : WITHDRAWAL_CAP;

        uint256 totalQueuedValue =
            _sharesToAssets(queuedSeniorShares, seniorNAV, sdcSenior.totalSupply()) +
            _sharesToAssets(queuedJuniorShares, juniorNAV, sdcJunior.totalSupply());

        if (!bunkerMode && totalQueuedValue > _mulWad(totalTVL, BUNKER_THRESHOLD)) {
            bunkerMode = true;
            capRate    = BUNKER_CAP;
            emit BunkerModeActivated(currentEpoch);
        }

        uint256 availableLiquidity = usdcReserve;

        // Senior first (structural priority)
        uint256 srCap       = _mulWad(seniorNAV, capRate);
        uint256 srProcessed = _processTrancheWithdrawals(true, srCap, availableLiquidity);
        availableLiquidity  = availableLiquidity > srProcessed ? availableLiquidity - srProcessed : 0;

        // Junior — with coverage-based cap override
        uint256 coverage    = getLeverageAdjustedCoverage();
        uint256 jrCapRate   = capRate;
        if (coverage < COVERAGE_HARD_FLOOR) {
            // Junior withdrawals fully paused
            jrCapRate = 0;
        } else if (coverage < COVERAGE_SOFT_FLOOR) {
            // Stricter cap during soft floor zone
            jrCapRate = WITHDRAWAL_STRESSED;
        }

        uint256 jrCap = _mulWad(juniorNAV, jrCapRate);
        _processTrancheWithdrawals(false, jrCap, availableLiquidity);

        if (bunkerMode) {
            uint256 remainingQueued =
                _sharesToAssets(queuedSeniorShares, seniorNAV, sdcSenior.totalSupply()) +
                _sharesToAssets(queuedJuniorShares, juniorNAV, sdcJunior.totalSupply());
            if (remainingQueued < _mulWad(totalTVL, 0.10e18)) {
                bunkerMode = false;
                emit BunkerModeDeactivated(currentEpoch);
            }
        }
    }

    function _processTrancheWithdrawals(
        bool isSenior,
        uint256 cap,
        uint256 availableLiquidity
    ) internal returns (uint256 totalDistributed) {
        if (cap == 0) return 0;  // paused

        uint256 processedValue;
        uint256 cursor     = isSenior ? lastProcessedSeniorWithdrawalId : lastProcessedJuniorWithdrawalId;
        uint256 iterations;

        for (uint256 i = cursor; i < nextRequestId && iterations < MAX_WITHDRAWAL_ITERATIONS; i++) {
            iterations++;
            WithdrawalRequest storage req = withdrawalRequests[i];
            if (req.fulfilled || req.isSenior != isSenior || req.shares == 0) continue;

            uint256 nav        = isSenior ? seniorNAV : juniorNAV;
            uint256 supply     = isSenior ? sdcSenior.totalSupply() : sdcJunior.totalSupply();
            uint256 assetValue = _sharesToAssets(req.shares, nav, supply);

            if (processedValue + assetValue > cap) continue;

            uint256 usdcOut;
            if (availableLiquidity >= assetValue) {
                usdcOut             = assetValue;
                usdcReserve         = usdcReserve > assetValue ? usdcReserve - assetValue : 0;
                availableLiquidity -= assetValue;
            } else {
                uint256 fromReserve = availableLiquidity;
                uint256 deficit     = assetValue - fromReserve;
                uint256 unwound     = _unwindForWithdrawal(deficit);
                usdcOut             = fromReserve + unwound;
                usdcReserve         = usdcReserve > fromReserve ? usdcReserve - fromReserve : 0;
                availableLiquidity  = 0;
            }

            req.fulfilled  = true;
            req.usdcAmount = usdcOut;
            processedValue += assetValue;
            totalDistributed += usdcOut;

            // Burn shares immediately so totalSupply tracks NAV correctly
            TrancheToken token = isSenior ? sdcSenior : sdcJunior;
            token.burn(address(this), req.shares);

            // Reduce NAV by full asset value (socializes any slippage immediately)
            if (isSenior) {
                seniorNAV           = seniorNAV > assetValue ? seniorNAV - assetValue : 0;
                queuedSeniorShares -= req.shares;
            } else {
                juniorNAV           = juniorNAV > assetValue ? juniorNAV - assetValue : 0;
                queuedJuniorShares -= req.shares;
            }

            emit WithdrawalFulfilled(i, usdcOut);
        }

        // Advance per-tranche cursor
        if (isSenior) {
            while (lastProcessedSeniorWithdrawalId < nextRequestId &&
                   (withdrawalRequests[lastProcessedSeniorWithdrawalId].fulfilled ||
                    withdrawalRequests[lastProcessedSeniorWithdrawalId].shares == 0 ||
                    !withdrawalRequests[lastProcessedSeniorWithdrawalId].isSenior)) {
                lastProcessedSeniorWithdrawalId++;
            }
        } else {
            while (lastProcessedJuniorWithdrawalId < nextRequestId &&
                   (withdrawalRequests[lastProcessedJuniorWithdrawalId].fulfilled ||
                    withdrawalRequests[lastProcessedJuniorWithdrawalId].shares == 0 ||
                    withdrawalRequests[lastProcessedJuniorWithdrawalId].isSenior)) {
                lastProcessedJuniorWithdrawalId++;
            }
        }
    }

    // ================================================================
    // INTERNAL — PROCESS DEPOSITS
    // ================================================================

    function _processDeposits() internal {
        while (lastProcessedDepositId < nextDepositRequestId &&
               (depositRequests[lastProcessedDepositId].processed ||
                depositRequests[lastProcessedDepositId].assets == 0)) {
            lastProcessedDepositId++;
        }

        for (uint256 i = lastProcessedDepositId; i < nextDepositRequestId; i++) {
            DepositRequest storage req = depositRequests[i];
            if (req.processed || req.assets == 0) continue;

            uint256 nav     = req.isSenior ? seniorNAV : juniorNAV;
            TrancheToken token = req.isSenior ? sdcSenior : sdcJunior;

            // Skip deposit into wiped tranche (NAV=0 but supply>0) to prevent price manipulation
            if (nav == 0 && token.totalSupply() > 0) continue;

            uint256 shares = _calculateShares(req.assets, nav, token.totalSupply());
            token.mint(address(this), shares);

            if (req.isSenior) {
                seniorNAV += req.assets;
            } else {
                juniorNAV += req.assets;
            }

            uint256 reservePortion = _mulWad(req.assets, RESERVE_TARGET);
            uint256 deployPortion  = req.assets - reservePortion;
            usdcReserve += reservePortion;
            if (deployPortion > 0) _deployCapital(deployPortion);

            req.processed = true;
            req.shares    = shares;
            pendingDeposits -= req.assets;

            if (req.isSenior) {
                pendingSeniorDeposits = pendingSeniorDeposits > req.assets ? pendingSeniorDeposits - req.assets : 0;
            } else {
                pendingJuniorDeposits = pendingJuniorDeposits > req.assets ? pendingJuniorDeposits - req.assets : 0;
            }

            emit DepositProcessed(i, shares);
        }

        while (lastProcessedDepositId < nextDepositRequestId &&
               (depositRequests[lastProcessedDepositId].processed ||
                depositRequests[lastProcessedDepositId].assets == 0)) {
            lastProcessedDepositId++;
        }
    }

    // ================================================================
    // LEVERAGE LOOP
    // ================================================================

    function _deployCapital(uint256 usdcAmount) internal {
        uint256 underlyingAmount = _usdcToUnderlying(usdcAmount);
        IERC20(address(stakedUnderlying)).forceApprove(address(lendingAdapter), underlyingAmount);
        lendingAdapter.depositCollateral(underlyingAmount);
    }

    function _rebalanceLeverage(uint256 targetLev) internal {
        uint256 equity = seniorNAV + juniorNAV;
        if (equity == 0) return;

        uint256 targetCollateral  = _mulWad(equity, targetLev);
        uint256 currentCollateral = lendingAdapter.collateralBalance();
        uint256 oldLev            = currentLeverage;

        if (targetCollateral > currentCollateral) {
            uint256 additional    = targetCollateral - currentCollateral;
            uint256 maxBorrowable = lendingAdapter.maxBorrow();
            uint256 usdcNeeded    = additional > maxBorrowable ? maxBorrowable : additional;

            if (usdcNeeded > 0) {
                lendingAdapter.borrow(usdcNeeded);
                uint256 underlyingGot = _usdcToUnderlying(usdcNeeded);
                IERC20(address(stakedUnderlying)).forceApprove(address(lendingAdapter), underlyingGot);
                lendingAdapter.depositCollateral(underlyingGot);
            }
        } else if (currentCollateral > targetCollateral) {
            _deleverageAmount(currentCollateral - targetCollateral);
        }

        emit LeverageAdjusted(oldLev, targetLev, lendingAdapter.collateralBalance(), lendingAdapter.debtBalance());
    }

    function _deleverageAmount(uint256 underlyingAmount) internal {
        if (underlyingAmount == 0) return;
        lendingAdapter.withdrawCollateral(underlyingAmount);
        uint256 usdcReceived = _underlyingToUsdc(underlyingAmount);
        uint256 debt         = lendingAdapter.debtBalance();
        uint256 repayAmount  = usdcReceived > debt ? debt : usdcReceived;

        if (repayAmount > 0) {
            usdc.forceApprove(address(lendingAdapter), repayAmount);
            lendingAdapter.repay(repayAmount);
        }

        uint256 excess = usdcReceived > repayAmount ? usdcReceived - repayAmount : 0;
        if (excess > 0) usdcReserve += excess;
    }

    function _unwindForWithdrawal(uint256 usdcNeeded) internal returns (uint256 usdcFreed) {
        uint256 unwindAmount = _mulWad(usdcNeeded, currentLeverage);
        uint256 collateral   = lendingAdapter.collateralBalance();
        if (unwindAmount > collateral) unwindAmount = collateral;

        if (unwindAmount > 0) {
            lendingAdapter.withdrawCollateral(unwindAmount);
            usdcFreed = _underlyingToUsdc(unwindAmount);

            uint256 debtPortion = Math.mulDiv(usdcFreed, currentLeverage - WAD, currentLeverage);
            uint256 debt        = lendingAdapter.debtBalance();
            uint256 repay       = debtPortion > debt ? debt : debtPortion;

            if (repay > 0) {
                usdc.forceApprove(address(lendingAdapter), repay);
                lendingAdapter.repay(repay);
            }

            usdcFreed = usdcFreed > repay ? usdcFreed - repay : 0;
        }
    }

    // ================================================================
    // TOKEN CONVERSION (vault-agnostic; concrete swap via Curve)
    // ================================================================

    function _usdcToUnderlying(uint256 usdcAmount) internal returns (uint256) {
        usdc.forceApprove(address(curvePool), usdcAmount);
        uint256 minOut = usdcAmount * 99 / 100;
        return curvePool.exchange(0, 1, usdcAmount, minOut);
    }

    function _underlyingToUsdc(uint256 underlyingAmount) internal returns (uint256) {
        IERC20(address(stakedUnderlying)).forceApprove(address(curvePool), underlyingAmount);
        uint256 minOut = underlyingAmount * 99 / 100;
        return curvePool.exchange(1, 0, underlyingAmount, minOut);
    }

    // ================================================================
    // HEALTH FACTOR MONITORING (keeper-callable every 30s)
    // ================================================================

    function checkHealthFactor() external onlyRole(KEEPER_ROLE) {
        uint256 hf = lendingAdapter.healthFactor();

        if (hf < HF_EMERGENCY) {
            isShutdown       = true;
            shutdownTimestamp = block.timestamp;
            _pause();
            _emergencyDeleverage(WAD);
            _convertRemainingToUsdc();
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
                _rebalanceLeverage(LEV_MIN);
                currentLeverage = LEV_MIN;
                emit EmergencyDeleveraged(hf, LEV_MIN);
            }
        }
    }

    function _emergencyDeleverage(uint256 targetLev) internal {
        uint256 equity    = seniorNAV + juniorNAV;
        if (equity == 0) return;
        uint256 target    = _mulWad(equity, targetLev);
        uint256 current   = lendingAdapter.collateralBalance();
        if (current > target) {
            _deleverageAmount(current - target);
            currentLeverage = targetLev;
        }
    }

    function _convertRemainingToUsdc() internal {
        // Repay debt first
        uint256 debt = lendingAdapter.debtBalance();
        if (debt > 0) {
            uint256 vaultUsdc = usdc.balanceOf(address(this));
            uint256 repayAmt  = debt > vaultUsdc ? vaultUsdc : debt;
            if (repayAmt > 0) {
                usdc.forceApprove(address(lendingAdapter), repayAmt);
                lendingAdapter.repay(repayAmt);
            }
        }
        // Withdraw remaining collateral
        uint256 remaining = lendingAdapter.collateralBalance();
        if (remaining > 0) {
            lendingAdapter.withdrawCollateral(remaining);
            uint256 usdcReceived = _underlyingToUsdc(remaining);
            uint256 remainingDebt = lendingAdapter.debtBalance();
            if (remainingDebt > 0 && usdcReceived > 0) {
                uint256 repay2 = remainingDebt > usdcReceived ? usdcReceived : remainingDebt;
                usdc.forceApprove(address(lendingAdapter), repay2);
                lendingAdapter.repay(repay2);
                usdcReceived -= repay2;
            }
            usdcReserve += usdcReceived;
        }
        currentLeverage = WAD;
    }

    // ================================================================
    // DUAL ORACLE
    // ================================================================

    function _checkOracleDeviation() internal {
        uint256 internalPrice = stakedUnderlying.convertToAssets(WAD);
        uint256 curvePrice    = curvePool.price_oracle();

        uint256 higher = internalPrice > curvePrice ? internalPrice : curvePrice;
        uint256 lower  = internalPrice > curvePrice ? curvePrice : internalPrice;

        if (higher > 0) {
            uint256 deviation = Math.mulDiv(higher - lower, WAD, higher);
            if (deviation > ORACLE_DEVIATION_MAX) {
                oracleCircuitBroken = true;
                emit OracleCircuitBroken(internalPrice, curvePrice);
            } else {
                oracleCircuitBroken = false;
            }
        }
    }

    // ================================================================
    // EPOCH SETTLEMENT
    // ================================================================

    /**
     * @notice Settle one epoch. Full pipeline:
     *  1. Dual oracle check
     *  2. Borrow cost circuit breaker
     *  3. HF cascade → determine newLeverage
     *  4. Rebalance leverage on-chain
     *  5. Derive underlying yield from exchange rate delta
     *  6. Validate keeper-supplied underlying price against oracle
     *  7. Execute waterfall (pure function)
     *  8. Update NAV
     *  9. Process deposits
     * 10. Process withdrawals (coverage-gated for junior)
     * 11. Replenish reserve
     * 12. Sync final leverage from adapter
     * 13. Store underlying price for next epoch
     */
    function settleEpoch(SignalData calldata signals) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (isShutdown) revert VaultShutdown();
        if (block.timestamp < lastEpochTimestamp + EPOCH_SECONDS - 10 minutes) revert EpochTooSoon();

        // 1. Oracle check
        _checkOracleDeviation();
        bool canAdjustLeverage = !oracleCircuitBroken;

        // 2-3. Borrow rate + HF cascade → newLeverage
        uint256 newLeverage = TARGET_LEVERAGE;
        uint256 borrowRate  = lendingAdapter.currentBorrowRate();
        if (borrowRate == 0) borrowRate = DEFAULT_BORROW;

        if (borrowRate >= BORROW_EMERGENCY) {
            newLeverage        = WAD;
            canAdjustLeverage  = true;
        } else if (borrowRate >= BORROW_DELEVERAGE) {
            newLeverage = WAD + _mulWad(newLeverage - WAD, 0.5e18);
        } else if (borrowRate >= BORROW_FREEZE) {
            if (newLeverage > currentLeverage) newLeverage = currentLeverage;
        }

        uint256 hf = lendingAdapter.healthFactor();
        if (hf < HF_EMERGENCY) {
            newLeverage = WAD; canAdjustLeverage = true;
        } else if (hf < HF_ACCELERATE) {
            uint256 excess = currentLeverage > WAD ? currentLeverage - WAD : 0;
            newLeverage    = currentLeverage - _mulWad(excess, 0.60e18);
            canAdjustLeverage = true;
        } else if (hf < HF_DELEVERAGE) {
            uint256 floor  = 1.25e18;
            uint256 excess = currentLeverage > floor ? currentLeverage - floor : 0;
            newLeverage    = currentLeverage - _mulWad(excess, 0.30e18);
            canAdjustLeverage = true;
        } else if (hf < HF_FREEZE) {
            if (newLeverage > currentLeverage) newLeverage = currentLeverage;
        }

        if (newLeverage > currentLeverage + LEV_RELEV_CAP) newLeverage = currentLeverage + LEV_RELEV_CAP;
        if (newLeverage > LEV_MAX) newLeverage = LEV_MAX;
        if (newLeverage < WAD)     newLeverage = WAD;
        if (bunkerMode && newLeverage > WAD) newLeverage = WAD;

        // 4. Rebalance
        if (canAdjustLeverage && newLeverage != currentLeverage) {
            _rebalanceLeverage(newLeverage);
        }

        // Actual leverage from adapter
        uint256 equity = seniorNAV + juniorNAV;
        uint256 actualLeverage = newLeverage;
        if (equity > 0) {
            uint256 actualCollateral = lendingAdapter.collateralBalance();
            if (actualCollateral > 0) {
                actualLeverage = Math.mulDiv(actualCollateral, WAD, equity);
                if (actualLeverage > LEV_MAX) actualLeverage = LEV_MAX;
                if (actualLeverage < WAD)     actualLeverage = WAD;
            }
        }

        // 5. Derive underlying yield from exchange rate delta
        uint256 currentRate = stakedUnderlying.convertToAssets(WAD);
        uint256 derivedEpochYield;
        if (lastExchangeRate > 0 && currentRate > lastExchangeRate) {
            derivedEpochYield = Math.mulDiv(currentRate - lastExchangeRate, WAD, lastExchangeRate);
        } else if (lastExchangeRate > 0) {
            derivedEpochYield = 0; // negative yield period
        } else {
            derivedEpochYield = SUSDAT_YIELD_FALLBACK / EPOCHS_PER_YEAR; // epoch 0 only
        }
        uint256 derivedAnnualYield = derivedEpochYield * EPOCHS_PER_YEAR;
        lastExchangeRate = currentRate;

        // 6. Validate keeper-supplied underlying price
        {
            (uint256 oraclePrice, ) = underlyingOracle.getPrice();
            uint256 deviation;
            if (signals.underlyingPrice > oraclePrice) {
                deviation = Math.mulDiv(signals.underlyingPrice - oraclePrice, WAD, oraclePrice);
            } else {
                deviation = Math.mulDiv(oraclePrice - signals.underlyingPrice, WAD, oraclePrice);
            }
            require(deviation <= 0.01e18, "underlying price mismatch vs oracle");
        }

        if (lastSettledUnderlyingPrice > 0) {
            require(signals.prevUnderlyingPrice == lastSettledUnderlyingPrice, "prevUnderlyingPrice mismatch");
        }

        int256 underlyingReturn = 0;
        if (signals.prevUnderlyingPrice > 0) {
            underlyingReturn = (int256(signals.underlyingPrice) - int256(signals.prevUnderlyingPrice))
                * int256(WAD) / int256(signals.prevUnderlyingPrice);
        }

        // 7. Execute waterfall
        WaterfallResult memory wf = _executeWaterfall(
            seniorNAV, juniorNAV, actualLeverage, underlyingReturn, borrowRate, derivedAnnualYield
        );

        // 8. Update NAV
        uint256 newSeniorNAV = seniorNAV + wf.seniorCoupon;
        if (newSeniorNAV > wf.seniorMgmtFee) { newSeniorNAV -= wf.seniorMgmtFee; } else { newSeniorNAV = 0; }
        if (wf.seniorImpairment > 0) {
            newSeniorNAV = newSeniorNAV > wf.seniorImpairment ? newSeniorNAV - wf.seniorImpairment : 0;
        }

        uint256 newJuniorNAV;
        if (wf.juniorNetDelta >= 0) {
            newJuniorNAV = juniorNAV + uint256(wf.juniorNetDelta);
        } else {
            uint256 loss = uint256(-wf.juniorNetDelta);
            newJuniorNAV = juniorNAV > loss ? juniorNAV - loss : 0;
        }

        seniorNAV       = newSeniorNAV;
        juniorNAV       = newJuniorNAV;
        currentLeverage = actualLeverage;
        currentEpoch++;
        lastEpochTimestamp = block.timestamp;
        accruedFees += wf.seniorMgmtFee + wf.juniorMgmtFee + wf.perfFee;

        // 9-11. Deposits → Withdrawals → Reserve
        _processDeposits();
        _processWithdrawals();
        _replenishReserve();

        // 12. Final leverage sync
        uint256 finalEquity = seniorNAV + juniorNAV;
        if (finalEquity > 0) {
            uint256 finalCollateral = lendingAdapter.collateralBalance();
            if (finalCollateral > 0) {
                currentLeverage = Math.mulDiv(finalCollateral, WAD, finalEquity);
                if (currentLeverage > LEV_MAX) currentLeverage = LEV_MAX;
                if (currentLeverage < WAD)     currentLeverage = WAD;
            } else {
                currentLeverage = WAD;
            }
        }

        // 13. Store underlying price
        lastSettledUnderlyingPrice = signals.underlyingPrice;

        emit EpochSettled(currentEpoch, seniorNAV, juniorNAV, currentLeverage, hf);
        emit WaterfallExecuted(currentEpoch, wf);
    }

    // ================================================================
    // WATERFALL — pure function
    // ================================================================

    /**
     * @notice Execute yield waterfall for one epoch.
     * @param srNAV            Senior NAV entering this epoch
     * @param jrNAV            Junior NAV entering this epoch
     * @param leverage         Actual leverage from adapter (not target)
     * @param underlyingReturn Price return of collateral token (WAD, signed)
     * @param borrowRate       Live borrow rate from adapter
     * @param annualYield      Underlying yield derived from exchange rate delta, annualized
     */
    function _executeWaterfall(
        uint256 srNAV,
        uint256 jrNAV,
        uint256 leverage,
        int256  underlyingReturn,
        uint256 borrowRate,
        uint256 annualYield
    ) internal view returns (WaterfallResult memory wf) {
        uint256 totalPool = srNAV + jrNAV;
        if (totalPool == 0) return wf;

        // Epoch yield and borrow cost
        uint256 weeklyYield  = annualYield / EPOCHS_PER_YEAR;
        uint256 weeklyBorrow = borrowRate  / EPOCHS_PER_YEAR;
        uint256 levMinusOne  = leverage > WAD ? leverage - WAD : 0;

        uint256 grossYield  = _mulWad(leverage, weeklyYield);
        uint256 borrowCost  = _mulWad(levMinusOne, weeklyBorrow);

        int256 poolYieldSigned;
        if (grossYield >= borrowCost) {
            wf.poolIncome   = _mulWad(totalPool, grossYield - borrowCost);
            poolYieldSigned = int256(wf.poolIncome);
        } else {
            uint256 negativeCarry = _mulWad(totalPool, borrowCost - grossYield);
            wf.poolIncome   = 0;
            poolYieldSigned = -int256(negativeCarry);
        }

        // Mark-to-market (leveraged, always to junior)
        if (underlyingReturn >= 0) {
            uint256 mtm   = Math.mulDiv(totalPool, uint256(underlyingReturn), WAD);
            wf.poolMTM    = int256(Math.mulDiv(mtm, leverage, WAD));
        } else {
            uint256 mtm   = Math.mulDiv(totalPool, uint256(-underlyingReturn), WAD);
            wf.poolMTM    = -int256(Math.mulDiv(mtm, leverage, WAD));
        }

        // ── Special case: junior fully wiped ──────────────────────────────
        // Senior becomes sole risk bearer and earns full pool yield (not capped at 8%)
        if (jrNAV == 0) {
            if (poolYieldSigned > 0) {
                wf.seniorCoupon  = uint256(poolYieldSigned);
                wf.seniorMgmtFee = 0; // no mgmt fee while senior bearing full risk
            }
            // MTM still applies to seniorNAV in this edge case (no junior buffer)
            return wf;
        }

        // ── Normal waterfall ──────────────────────────────────────────────
        uint256 maxSeniorCoupon = Math.mulDiv(srNAV, SR_GROSS_APY, EPOCHS_PER_YEAR * WAD);
        wf.seniorMgmtFee        = Math.mulDiv(srNAV, srMgmtFee,   EPOCHS_PER_YEAR * WAD);

        if (poolYieldSigned > 0) {
            uint256 available   = uint256(poolYieldSigned);
            wf.seniorCoupon     = maxSeniorCoupon > available ? available : maxSeniorCoupon;
            if (wf.seniorCoupon + wf.seniorMgmtFee > available) {
                wf.seniorMgmtFee = available > wf.seniorCoupon ? available - wf.seniorCoupon : 0;
            }
        } else {
            wf.seniorCoupon  = 0;
            wf.seniorMgmtFee = 0;
        }

        uint256 seniorCosts  = wf.seniorCoupon + wf.seniorMgmtFee;
        uint256 jrGrossYield = 0;
        if (poolYieldSigned > 0 && uint256(poolYieldSigned) > seniorCosts) {
            jrGrossYield = uint256(poolYieldSigned) - seniorCosts;
        }

        wf.perfFee      = jrGrossYield > 0 ? Math.mulDiv(jrGrossYield, jrPerfFee, WAD) : 0;
        wf.juniorMgmtFee = poolYieldSigned > 0
            ? Math.mulDiv(jrNAV, jrMgmtFee, EPOCHS_PER_YEAR * WAD)
            : 0;

        int256 jrYieldNet  = int256(jrGrossYield) - int256(wf.perfFee) - int256(wf.juniorMgmtFee);
        if (poolYieldSigned < 0) jrYieldNet += poolYieldSigned;
        wf.juniorNetDelta  = jrYieldNet + wf.poolMTM;

        // Senior impairment only after junior is fully consumed
        int256 projectedJrNAV = int256(jrNAV) + wf.juniorNetDelta;
        if (projectedJrNAV < 0) {
            wf.seniorImpairment = uint256(-projectedJrNAV);
            wf.juniorNetDelta   = -int256(jrNAV);
        }
    }

    // ================================================================
    // RESERVE REPLENISHMENT
    // ================================================================

    function _replenishReserve() internal {
        uint256 totalTVL = seniorNAV + juniorNAV;
        if (totalTVL == 0) return;

        uint256 target = _mulWad(totalTVL, RESERVE_TARGET);
        if (usdcReserve >= target) return;

        // Don't pull collateral if HF is stressed
        if (lendingAdapter.healthFactor() < HF_FREEZE) return;

        uint256 deficit  = target - usdcReserve;
        uint256 maxPull  = _mulWad(totalTVL, 0.02e18);  // max 2% TVL per epoch
        uint256 pull     = deficit > maxPull ? maxPull : deficit;

        if (pull > 0 && lendingAdapter.collateralBalance() > pull) {
            _deleverageAmount(pull);
        }
    }

    // ================================================================
    // LIVE NAV
    // ================================================================

    function _liveTotalAssets() internal view returns (uint256) {
        uint256 collateral     = lendingAdapter.collateralBalance();
        uint256 debt           = lendingAdapter.debtBalance();
        uint256 collateralUsdc = collateral > 0
            ? Math.mulDiv(collateral, stakedUnderlying.convertToAssets(WAD), WAD)
            : 0;
        uint256 totalAssets    = usdcReserve + collateralUsdc;
        return totalAssets > debt ? totalAssets - debt : 0;
    }

    function _liveSeniorNAV() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastEpochTimestamp;
        if (elapsed > EPOCH_SECONDS) elapsed = EPOCH_SECONDS;
        uint256 accrual = Math.mulDiv(seniorNAV, SR_NET_APY * elapsed, 365 days * WAD);
        return seniorNAV + accrual;
    }

    function _liveJuniorNAV() internal view returns (uint256) {
        uint256 totalLive = _liveTotalAssets();
        uint256 srLive    = _liveSeniorNAV();
        return totalLive > srLive ? totalLive - srLive : 0;
    }

    // ================================================================
    // VIEW FUNCTIONS
    // ================================================================

    function currentRatio() external view returns (uint256) {
        uint256 total = seniorNAV + juniorNAV;
        if (total == 0) return 0.70e18;
        return Math.mulDiv(seniorNAV, WAD, total);
    }

    function tvl() external view returns (uint256) { return seniorNAV + juniorNAV; }

    function seniorSharePrice() external view returns (uint256) {
        uint256 supply = sdcSenior.totalSupply();
        return supply == 0 ? USDC_DECIMALS : Math.mulDiv(seniorNAV, 1e18, supply);
    }

    function juniorSharePrice() external view returns (uint256) {
        uint256 supply = sdcJunior.totalSupply();
        return supply == 0 ? USDC_DECIMALS : Math.mulDiv(juniorNAV, 1e18, supply);
    }

    function canSettle() external view returns (bool) {
        return block.timestamp >= lastEpochTimestamp + EPOCH_SECONDS - 10 minutes;
    }

    function getHealthFactor() external view returns (uint256) { return lendingAdapter.healthFactor(); }
    function getBorrowRate()   external view returns (uint256) { return lendingAdapter.currentBorrowRate(); }

    function getPosition() external view returns (uint256 collateral, uint256 debt, uint256 hf) {
        collateral = lendingAdapter.collateralBalance();
        debt       = lendingAdapter.debtBalance();
        hf         = lendingAdapter.healthFactor();
    }

    // ================================================================
    // ADMIN / GOVERNANCE
    // ================================================================

    function emergencyShutdown() external onlyRole(GUARDIAN_ROLE) {
        isShutdown        = true;
        shutdownTimestamp = block.timestamp;
        _pause();
        _emergencyDeleverage(WAD);
        _convertRemainingToUsdc();
        emit EmergencyShutdown(block.timestamp);
    }

    function emergencyClaim(bool isSenior) external nonReentrant {
        if (!isShutdown) revert NotShutdown();

        if (!isSenior) {
            require(
                sdcSenior.totalSupply() == 0 || block.timestamp >= shutdownTimestamp + 30 days,
                "senior claims first"
            );
        }

        TrancheToken token     = isSenior ? sdcSenior : sdcJunior;
        uint256 userShares     = token.balanceOf(msg.sender);
        if (userShares == 0) revert ZeroAmount();

        uint256 supply    = token.totalSupply();
        uint256 nav       = isSenior ? seniorNAV : juniorNAV;
        uint256 usdcOwed  = Math.mulDiv(userShares, nav, supply);

        uint256 rawBalance = usdc.balanceOf(address(this));
        uint256 available  = rawBalance > pendingDeposits ? rawBalance - pendingDeposits : 0;
        if (usdcOwed > available) usdcOwed = available;

        token.burn(msg.sender, userShares);

        if (isSenior) {
            seniorNAV = seniorNAV > usdcOwed ? seniorNAV - usdcOwed : 0;
        } else {
            juniorNAV = juniorNAV > usdcOwed ? juniorNAV - usdcOwed : 0;
        }

        if (usdcOwed > 0) usdc.safeTransfer(msg.sender, usdcOwed);
        emit EmergencyClaim(msg.sender, isSenior, usdcOwed);
    }

    function withdrawFees(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 fees         = accruedFees;
        uint256 available    = usdc.balanceOf(address(this));
        uint256 protected    = usdcReserve + pendingDeposits;
        uint256 withdrawable = available > protected ? available - protected : 0;
        uint256 payout       = fees > withdrawable ? withdrawable : fees;
        accruedFees          = fees - payout;
        if (payout > 0) usdc.safeTransfer(to, payout);
    }

    /**
     * @notice Update fee parameters. Requires timelock — changes take effect 7 days after queuing.
     * @dev    Hard ceilings enforced: srMgmt and jrMgmt <= 2%, jrPerf <= 20%.
     */
    function queueSetFees(uint256 _srMgmtFee, uint256 _jrMgmtFee, uint256 _jrPerfFee)
        external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 id)
    {
        require(_srMgmtFee <= MAX_MGMT_FEE, "sr mgmt fee exceeds ceiling");
        require(_jrMgmtFee <= MAX_MGMT_FEE, "jr mgmt fee exceeds ceiling");
        require(_jrPerfFee <= MAX_PERF_FEE, "jr perf fee exceeds ceiling");

        id = nextTimelockId++;
        bytes32 hash = keccak256(abi.encode("setFees", _srMgmtFee, _jrMgmtFee, _jrPerfFee));
        timelockRequests[id] = TimelockRequest(hash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockQueued(id, hash, block.timestamp + TIMELOCK_DELAY);
    }

    function executeSetFees(uint256 id, uint256 _srMgmtFee, uint256 _jrMgmtFee, uint256 _jrPerfFee)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        TimelockRequest storage req = timelockRequests[id];
        require(!req.executed, "already executed");
        require(block.timestamp >= req.executeAfter, "timelock not elapsed");
        require(req.actionHash == keccak256(abi.encode("setFees", _srMgmtFee, _jrMgmtFee, _jrPerfFee)), "hash mismatch");
        req.executed = true;
        srMgmtFee = _srMgmtFee;
        jrMgmtFee = _jrMgmtFee;
        jrPerfFee = _jrPerfFee;
        emit FeesUpdated(_srMgmtFee, _jrMgmtFee, _jrPerfFee);
    }

    function queueSetLendingAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 id) {
        require(adapter != address(0), "zero addr");
        id = nextTimelockId++;
        bytes32 hash = keccak256(abi.encode("setLendingAdapter", adapter));
        timelockRequests[id] = TimelockRequest(hash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockQueued(id, hash, block.timestamp + TIMELOCK_DELAY);
    }

    function executeSetLendingAdapter(uint256 id, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TimelockRequest storage req = timelockRequests[id];
        require(!req.executed, "already executed");
        require(block.timestamp >= req.executeAfter, "timelock not elapsed");
        require(req.actionHash == keccak256(abi.encode("setLendingAdapter", adapter)), "hash mismatch");
        req.executed   = true;
        lendingAdapter = ILendingAdapter(adapter);
        emit TimelockExecuted(id);
    }

    function queueSetCurvePool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 id) {
        require(pool != address(0), "zero addr");
        id = nextTimelockId++;
        bytes32 hash = keccak256(abi.encode("setCurvePool", pool));
        timelockRequests[id] = TimelockRequest(hash, block.timestamp + TIMELOCK_DELAY, false);
        emit TimelockQueued(id, hash, block.timestamp + TIMELOCK_DELAY);
    }

    function executeSetCurvePool(uint256 id, address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TimelockRequest storage req = timelockRequests[id];
        require(!req.executed, "already executed");
        require(block.timestamp >= req.executeAfter, "timelock not elapsed");
        require(req.actionHash == keccak256(abi.encode("setCurvePool", pool)), "hash mismatch");
        req.executed = true;
        curvePool    = ICurvePool(pool);
        emit TimelockExecuted(id);
    }

    function setTVLCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) { tvlCap = cap; }
    function pause()   external onlyRole(GUARDIAN_ROLE)     { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    // ================================================================
    // INTERNAL HELPERS
    // ================================================================

    function _checkTVLCapWithPending(uint256 depositAmount) internal view {
        if (tvlCap > 0) {
            uint256 newTVL = seniorNAV + juniorNAV + pendingDeposits + depositAmount;
            if (newTVL > tvlCap) revert TVLCapExceeded();
        }
    }

    function _calculateShares(uint256 assets, uint256 nav, uint256 totalSupply)
        internal pure returns (uint256)
    {
        if (totalSupply == 0 || nav == 0) return assets * 1e12;
        return Math.mulDiv(assets, totalSupply, nav);
    }

    function _sharesToAssets(uint256 shares, uint256 nav, uint256 totalSupply)
        internal pure returns (uint256)
    {
        if (totalSupply == 0) return 0;
        return Math.mulDiv(shares, nav, totalSupply);
    }

    function _mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, WAD);
    }
}
