// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Vault } from "../Vault.sol";
import { IVault } from "../interfaces/IVault.sol";

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
        // Deposit tokens to vault
        vault.depositToken(
            IVault.TokenParams({ token: token, amount: amount, recipient: address(0) })
        );
        attacking = false;
    }

    function attackWithdraw(address token, uint256 amount, address to) external onlyOwner {
        attacking = true;
        // Withdraw tokens from vault
        vault.withdrawToken(IVault.TokenParams({ token: token, amount: amount, recipient: to }));
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
            // Try to deposit during receive callback (should fail)
            vault.depositToken(
                IVault.TokenParams({ token: address(0), amount: 1, recipient: address(0) })
            ); // This should fail due to reentrancy guard
        }
        // If we're attacking and the reentrant function is set to withdrawToken,
        // try to call withdrawToken again to test reentrancy protection
        else if (
            attacking && keccak256(bytes(reentrantFunction)) == keccak256(bytes("withdrawToken"))
        ) {
            // Try to withdraw during receive callback (should fail)
            vault.withdrawToken(
                IVault.TokenParams({ token: address(0), amount: 1, recipient: msg.sender })
            ); // This should fail due to reentrancy guard
        }
    }

    // Function to handle ERC20 token callbacks (for tokens that have hooks)
    function onERC20Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        // If we're attacking and the reentrant function is set to depositToken,
        // try to call depositToken again to test reentrancy protection
        if (attacking && keccak256(bytes(reentrantFunction)) == keccak256(bytes("depositToken"))) {
            // Try to deposit during token receive callback (should fail)
            vault.depositToken(
                IVault.TokenParams({ token: address(0), amount: 1, recipient: address(0) })
            ); // This should fail due to reentrancy guard
        }
        // If we're attacking and the reentrant function is set to withdrawToken,
        // try to call withdrawToken again to test reentrancy protection
        else if (
            attacking && keccak256(bytes(reentrantFunction)) == keccak256(bytes("withdrawToken"))
        ) {
            // Try to withdraw during token receive callback (should fail)
            vault.withdrawToken(
                IVault.TokenParams({ token: address(0), amount: 1, recipient: msg.sender })
            ); // This should fail due to reentrancy guard
        }
        return this.onERC20Received.selector;
    }
}
