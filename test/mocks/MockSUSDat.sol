// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Mock sUSDat for vault testing. Includes convertToAssets for dual oracle check.
contract MockSUSDat is ERC20 {
    address public immutable asset_;
    address public immutable oracle_;
    uint256 public exchangeRate = 1e18; // 1 sUSDat = 1 USDat default

    constructor(address _asset, address _oracle) ERC20("Mock sUSDat", "sUSDat") {
        asset_ = _asset;
        oracle_ = _oracle;
    }

    function decimals() public pure override returns (uint8) { return 6; }

    function asset() external view returns (address) { return asset_; }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * exchangeRate) / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / exchangeRate;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        IERC20(asset_).transferFrom(msg.sender, address(this), assets);
        shares = assets;
        _mint(receiver, shares);
    }

    function totalAssets() external view returns (uint256) {
        return IERC20(asset_).balanceOf(address(this));
    }

    function requestRedeem(uint256, uint256) external pure returns (uint256) { return 0; }
    function claim() external pure returns (uint256) { return 0; }
    function claimBatch(uint256[] calldata) external pure returns (uint256) { return 0; }
    function depositWithMinShares(uint256, address, uint256) external pure returns (uint256) { return 0; }
    function mintWithMaxAssets(uint256, address, uint256) external pure returns (uint256) { return 0; }
    function depositFeeBps() external pure returns (uint256) { return 10; }
    function usdatBalance() external view returns (uint256) { return IERC20(asset_).balanceOf(address(this)); }
    function strcBalance() external pure returns (uint256) { return 0; }
    function vestingAmount() external pure returns (uint256) { return 0; }
    function getUnvestedAmount() external pure returns (uint256) { return 0; }
    function getWithdrawalQueue() external pure returns (address) { return address(0); }
    function getStrcOracle() external view returns (address) { return oracle_; }
    function isBlacklisted(address) external pure returns (bool) { return false; }

    // Test helpers
    function setExchangeRate(uint256 rate) external { exchangeRate = rate; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
