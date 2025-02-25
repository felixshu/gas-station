// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Vault } from "../Vault.sol";

/**
 * @title MockAttacker
 * @dev Contract used to test reentrancy protection in the Vault contract
 */
contract MockAttacker is Ownable {
    Vault public vault;
    string public reentrantFunction;
    bool public attacking;

    constructor(address _vault) Ownable(msg.sender) {
        vault = Vault(payable(_vault));
    }

    function setReentrantFunction(string memory _function) external onlyOwner {
        reentrantFunction = _function;
    }

    function attack(address token, uint256 amount) external onlyOwner {
        attacking = true;
        // Approve the vault to spend tokens
        IERC20(token).approve(address(vault), amount);
        // Attempt to deposit tokens
        vault.depositToken(token, amount);
        attacking = false;
    }

    function attackWithdraw(address token, uint256 amount, address to) external onlyOwner {
        attacking = true;
        // Attempt to withdraw tokens
        vault.withdrawToken(token, amount, to);
        attacking = false;
    }

    function transferOwnership(address target, address newOwner) external onlyOwner {
        // Helper function to transfer ownership of another contract
        Ownable(target).transferOwnership(newOwner);
    }

    // Fallback function to receive ETH
    receive() external payable {
        // If we're attacking and the reentrant function is set to depositToken,
        // try to call depositToken again to test reentrancy protection
        if (attacking && keccak256(bytes(reentrantFunction)) == keccak256(bytes("depositToken"))) {
            vault.depositToken(address(0), 1); // This should fail due to reentrancy guard
        }
        // If we're attacking and the reentrant function is set to withdrawToken,
        // try to call withdrawToken again to test reentrancy protection
        else if (
            attacking && keccak256(bytes(reentrantFunction)) == keccak256(bytes("withdrawToken"))
        ) {
            vault.withdrawToken(address(0), 1, msg.sender); // This should fail due to reentrancy guard
        }
    }

    // Function to handle ERC20 token callbacks (for tokens that have hooks)
    function onERC20Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        // If we're attacking and the reentrant function is set to depositToken,
        // try to call depositToken again to test reentrancy protection
        if (attacking && keccak256(bytes(reentrantFunction)) == keccak256(bytes("depositToken"))) {
            vault.depositToken(address(0), 1); // This should fail due to reentrancy guard
        }
        // If we're attacking and the reentrant function is set to withdrawToken,
        // try to call withdrawToken again to test reentrancy protection
        else if (
            attacking && keccak256(bytes(reentrantFunction)) == keccak256(bytes("withdrawToken"))
        ) {
            vault.withdrawToken(address(0), 1, msg.sender); // This should fail due to reentrancy guard
        }
        return this.onERC20Received.selector;
    }
}
