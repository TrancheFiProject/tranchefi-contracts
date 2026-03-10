// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title  TrancheToken
 * @notice ERC20 token representing a tranche position in TrancheFiVault.
 * @dev    Only the vault (set at deploy) can mint/burn.
 *         sdcSENIOR = senior tranche shares
 *         sdcJUNIOR = junior tranche shares
 */
contract TrancheToken is ERC20 {
    address public immutable vault;

    error OnlyVault();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(string memory name_, string memory symbol_, address vault_) ERC20(name_, symbol_) {
        require(vault_ != address(0), "zero vault");
        vault = vault_;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
