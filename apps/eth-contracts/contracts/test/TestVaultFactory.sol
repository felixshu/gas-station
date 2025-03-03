// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VaultFactory } from "../VaultFactory.sol";

/**
 * @title TestVaultFactory
 * @dev Test version of VaultFactory that exposes pause and unpause functions for testing
 */
contract TestVaultFactory is VaultFactory {
    /**
     * @dev Pauses the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
