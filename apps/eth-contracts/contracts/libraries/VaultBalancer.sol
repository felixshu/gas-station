// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Errors } from "./Errors.sol";

/**
 * @title VaultBalancer
 * @dev Internal library for balancing ETH across vaults
 * @notice This library is implemented as an internal library to avoid upgrade safety issues
 * with external libraries in upgradeable contracts. Internal libraries are included in the
 * contract bytecode and don't require the unsafeAllowLinkedLibraries flag.
 */
library VaultBalancer {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev Find vaults that need balancing based on ETH thresholds
     * @param allVaultAddresses Array of all vault addresses to search through
     * @param lowerThreshold Minimum ETH balance threshold
     * @param upperThreshold Maximum ETH balance threshold
     * @param targetEthBalance Target ETH balance for vaults below threshold
     * @return sourceVaults Array of vault addresses with excess ETH
     * @return targetVaults Array of vault addresses that need more ETH
     * @return targetBalances Array of target ETH balances for each target vault
     */
    function findVaultsForBalancing(
        address[] memory allVaultAddresses,
        uint256 lowerThreshold,
        uint256 upperThreshold,
        uint256 targetEthBalance
    )
        internal
        view
        returns (
            address[] memory sourceVaults,
            address[] memory targetVaults,
            uint256[] memory targetBalances
        )
    {
        // Validate inputs
        _validateBalancingInputs(
            lowerThreshold,
            upperThreshold,
            targetEthBalance,
            allVaultAddresses.length
        );

        // Count vaults that need balancing and get their counts
        (uint256 sourceCount, uint256 targetCount) = _countVaultsForBalancing(
            allVaultAddresses,
            lowerThreshold,
            upperThreshold
        );

        // If no vaults need balancing, return empty arrays
        if (sourceCount == 0 || targetCount == 0) {
            return (new address[](0), new address[](0), new uint256[](0));
        }

        // Create and fill the arrays with vaults that need balancing
        return
            _createBalancingArrays(
                allVaultAddresses,
                lowerThreshold,
                upperThreshold,
                targetEthBalance,
                sourceCount,
                targetCount
            );
    }

    /**
     * @dev Validate inputs for the balancing function
     * @param lowerThreshold Minimum ETH balance threshold
     * @param upperThreshold Maximum ETH balance threshold
     * @param targetEthBalance Target ETH balance for vaults below threshold
     * @param vaultCount Number of vaults to check
     */
    function _validateBalancingInputs(
        uint256 lowerThreshold,
        uint256 upperThreshold,
        uint256 targetEthBalance,
        uint256 vaultCount
    ) private pure {
        if (lowerThreshold >= upperThreshold)
            revert Errors.InvalidLimits(lowerThreshold, upperThreshold);
        if (targetEthBalance <= lowerThreshold || targetEthBalance >= upperThreshold)
            revert Errors.InvalidLimits(targetEthBalance, upperThreshold);
        if (vaultCount == 0) revert Errors.InvalidLimits(vaultCount, 1);
    }

    /**
     * @dev Count vaults that need balancing
     * @param allVaultAddresses Array of all vault addresses to search through
     * @param lowerThreshold Minimum ETH balance threshold
     * @param upperThreshold Maximum ETH balance threshold
     * @return sourceCount Number of vaults with excess ETH
     * @return targetCount Number of vaults that need more ETH
     */
    function _countVaultsForBalancing(
        address[] memory allVaultAddresses,
        uint256 lowerThreshold,
        uint256 upperThreshold
    ) private view returns (uint256 sourceCount, uint256 targetCount) {
        sourceCount = 0;
        targetCount = 0;

        for (uint256 i = 0; i < allVaultAddresses.length; i++) {
            address vaultAddr = allVaultAddresses[i];
            uint256 balance = vaultAddr.balance;

            if (balance > upperThreshold) {
                sourceCount++;
            } else if (balance < lowerThreshold) {
                targetCount++;
            }
        }

        return (sourceCount, targetCount);
    }

    /**
     * @dev Create and fill arrays for balancing
     * @param allVaultAddresses Array of all vault addresses to search through
     * @param lowerThreshold Minimum ETH balance threshold
     * @param upperThreshold Maximum ETH balance threshold
     * @param targetEthBalance Target ETH balance for vaults below threshold
     * @param sourceCount Number of vaults with excess ETH
     * @param targetCount Number of vaults that need more ETH
     * @return sourceVaults Array of vault addresses with excess ETH
     * @return targetVaults Array of vault addresses that need more ETH
     * @return targetBalances Array of target ETH balances for each target vault
     */
    function _createBalancingArrays(
        address[] memory allVaultAddresses,
        uint256 lowerThreshold,
        uint256 upperThreshold,
        uint256 targetEthBalance,
        uint256 sourceCount,
        uint256 targetCount
    )
        private
        view
        returns (
            address[] memory sourceVaults,
            address[] memory targetVaults,
            uint256[] memory targetBalances
        )
    {
        // Create arrays with exact sizes
        sourceVaults = new address[](sourceCount);
        targetVaults = new address[](targetCount);
        targetBalances = new uint256[](targetCount);

        // Fill the arrays
        uint256 sourceIndex = 0;
        uint256 targetIndex = 0;

        for (uint256 i = 0; i < allVaultAddresses.length; i++) {
            address vaultAddr = allVaultAddresses[i];
            uint256 balance = vaultAddr.balance;

            if (balance > upperThreshold) {
                sourceVaults[sourceIndex] = vaultAddr;
                sourceIndex++;
            } else if (balance < lowerThreshold) {
                targetVaults[targetIndex] = vaultAddr;
                targetBalances[targetIndex] = targetEthBalance; // Set target to the desired balance
                targetIndex++;
            }
        }

        return (sourceVaults, targetVaults, targetBalances);
    }

    /**
     * @dev Calculate ETH distribution for balancing vaults
     * @param sourceVaults Array of vault addresses with excess ETH
     * @param targetVaults Array of vault addresses that need more ETH
     * @param targetBalances Array of target ETH balances for each target vault
     * @return totalEthNeeded Total ETH needed for balancing
     * @return totalAvailableEth Total ETH available from source vaults
     * @return currentBalances Current ETH balances of target vaults
     */
    function calculateEthDistribution(
        address[] memory sourceVaults,
        address[] memory targetVaults,
        uint256[] memory targetBalances
    )
        internal
        view
        returns (
            uint256 totalEthNeeded,
            uint256 totalAvailableEth,
            uint256[] memory currentBalances
        )
    {
        // Validate inputs
        if (targetVaults.length != targetBalances.length)
            revert Errors.InvalidLimits(targetVaults.length, targetBalances.length);
        if (sourceVaults.length == 0 || targetVaults.length == 0) revert Errors.InvalidLimits(0, 1);

        // Calculate how much ETH we need in total for target vaults
        totalEthNeeded = 0;
        currentBalances = new uint256[](targetVaults.length);

        for (uint256 i = 0; i < targetVaults.length; i++) {
            address targetVault = targetVaults[i];

            // Get current balance
            currentBalances[i] = targetVault.balance;

            // If target balance is higher than current, add the difference to total needed
            if (targetBalances[i] > currentBalances[i]) {
                totalEthNeeded += (targetBalances[i] - currentBalances[i]);
            }
        }

        // Calculate available ETH from source vaults
        totalAvailableEth = 0;
        for (uint256 i = 0; i < sourceVaults.length; i++) {
            address sourceVault = sourceVaults[i];

            // We'll consider all ETH in source vaults as available
            totalAvailableEth += sourceVault.balance;
        }

        return (totalEthNeeded, totalAvailableEth, currentBalances);
    }
}
