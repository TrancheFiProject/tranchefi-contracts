// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";

/**
 * @title  MockLendingAdapter
 * @notice Test mock simulating Aave/Morpho lending behavior.
 * @dev    Tracks collateral/debt balances internally.
 *         No actual lending — just accounting for test purposes.
 */
contract MockLendingAdapter is ILendingAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken; // sUSDat
    IERC20 public immutable debtToken;       // USDC

    uint256 public _collateral;
    uint256 public _debt;
    uint256 public _borrowRate;
    uint256 public _liqThreshold;

    constructor(address _collateralToken, address _debtToken) {
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        _borrowRate = 0.055e18;     // 5.5% default
        _liqThreshold = 0.825e18;   // 82.5% default
    }

    function depositCollateral(uint256 amount) external override {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        _collateral += amount;
    }

    function withdrawCollateral(uint256 amount) external override {
        require(amount <= _collateral, "insufficient collateral");
        _collateral -= amount;
        collateralToken.transfer(msg.sender, amount);
    }

    function borrow(uint256 amount) external override {
        require(amount <= maxBorrow(), "exceeds max borrow");
        _debt += amount;
        debtToken.transfer(msg.sender, amount);
    }

    function repay(uint256 amount) external override {
        debtToken.transferFrom(msg.sender, address(this), amount);
        _debt = _debt > amount ? _debt - amount : 0;
    }

    function collateralBalance() external view override returns (uint256) {
        return _collateral;
    }

    function debtBalance() external view override returns (uint256) {
        return _debt;
    }

    function healthFactor() external view override returns (uint256) {
        if (_debt == 0) return type(uint256).max;
        return (_collateral * _liqThreshold) / _debt;
    }

    function currentBorrowRate() external view override returns (uint256) {
        return _borrowRate;
    }

    function maxBorrow() public view override returns (uint256) {
        uint256 maxDebt = (_collateral * _liqThreshold) / 1e18;
        return maxDebt > _debt ? maxDebt - _debt : 0;
    }

    function liquidationThreshold() external view override returns (uint256) {
        return _liqThreshold;
    }

    // --- Test helpers ---
    function setBorrowRate(uint256 rate) external { _borrowRate = rate; }
    function setLiqThreshold(uint256 lt) external { _liqThreshold = lt; }
    function setDebt(uint256 d) external { _debt = d; }
    function setCollateral(uint256 c) external { _collateral = c; }
    function fundDebtToken(uint256 amount) external {
        // For tests: pre-fund so borrow() can transfer
    }
}
