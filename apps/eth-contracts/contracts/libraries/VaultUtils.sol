// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Vault } from "../Vault.sol";
import { IVault } from "../interfaces/IVault.sol";

/**
 * @title VaultUtils
 * @dev Internal library for vault management operations
 * @notice This library is implemented as an internal library to avoid upgrade safety issues
 * with external libraries in upgradeable contracts. Internal libraries are included in the
 * contract bytecode and don't require the unsafeAllowLinkedLibraries flag.
 */
library VaultUtils {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev Struct to hold vault information
     */
    struct VaultInfo {
        address vaultAddress;
        address owner;
        uint256 ethBalance;
        bool isActive;
    }

    /**
     * @dev Move ETH between vaults
     * @param sourceVaults Array of vault addresses with excess ETH
     * @param targetVaults Array of vault addresses that need more ETH
     * @param targetBalances Array of target ETH balances for each target vault
     * @param currentBalances Array of current ETH balances for each target vault
     * @return totalMoved Total amount of ETH moved between vaults
     */
    function moveEthBetweenVaults(
        address[] calldata sourceVaults,
        address[] calldata targetVaults,
        uint256[] calldata targetBalances,
        uint256[] memory currentBalances
    ) internal returns (uint256 totalMoved) {
        totalMoved = 0;
        uint256 sourceIndex = 0;
        address currentSourceAddr = sourceVaults[sourceIndex];
        Vault currentSource = Vault(payable(currentSourceAddr));
        uint256 currentSourceBalance = currentSourceAddr.balance;

        // For each target vault that needs ETH
        for (uint256 i = 0; i < targetVaults.length; i++) {
            uint256 amountNeeded = 0;
            if (targetBalances[i] > currentBalances[i]) {
                amountNeeded = targetBalances[i] - currentBalances[i];
            } else {
                continue; // Skip if this vault doesn't need more ETH
            }

            // Process transfers for this target vault
            uint256 amountMoved = _processEthTransfersForTarget(
                sourceVaults,
                targetVaults[i],
                amountNeeded,
                sourceIndex,
                currentSourceAddr,
                currentSource,
                currentSourceBalance
            );

            // Update state variables based on the transfer results
            totalMoved += amountMoved;

            // If we couldn't move all the ETH needed, we've exhausted all sources
            if (amountMoved < amountNeeded) {
                break;
            }
        }

        return totalMoved;
    }

    /**
     * @dev Helper function to process ETH transfers for a single target vault
     * @param sourceVaults Array of source vault addresses
     * @param targetVault Target vault address
     * @param amountNeeded Amount of ETH needed by the target vault
     * @param sourceIndex Current index in the sourceVaults array
     * @param currentSourceAddr Current source vault address
     * @param currentSource Current source vault contract
     * @param currentSourceBalance Current source vault ETH balance
     * @return amountMoved Total amount of ETH moved to the target vault
     */
    function _processEthTransfersForTarget(
        address[] calldata sourceVaults,
        address targetVault,
        uint256 amountNeeded,
        uint256 sourceIndex,
        address currentSourceAddr,
        Vault currentSource,
        uint256 currentSourceBalance
    ) private returns (uint256 amountMoved) {
        amountMoved = 0;

        // Keep moving ETH until this target vault has enough
        while (amountNeeded > 0) {
            // If current source is depleted, move to next source
            if (currentSourceBalance == 0) {
                sourceIndex++;
                if (sourceIndex >= sourceVaults.length) {
                    // We've exhausted all sources
                    return amountMoved;
                }
                currentSourceAddr = sourceVaults[sourceIndex];
                currentSource = Vault(payable(currentSourceAddr));
                currentSourceBalance = currentSourceAddr.balance;
            }

            // Calculate how much to move from this source
            uint256 amountToMove = currentSourceBalance > amountNeeded
                ? amountNeeded
                : currentSourceBalance;

            // Move ETH from source to target
            try
                currentSource.sendEth(
                    IVault.EthParams({ amount: amountToMove, recipient: targetVault })
                )
            {
                // Update balances
                currentSourceBalance -= amountToMove;
                amountNeeded -= amountToMove;
                amountMoved += amountToMove;
            } catch {
                // If transfer fails, try next source
                sourceIndex++;
                if (sourceIndex >= sourceVaults.length) {
                    // If we've tried all sources, return what we've moved so far
                    return amountMoved;
                }
                currentSourceAddr = sourceVaults[sourceIndex];
                currentSource = Vault(payable(currentSourceAddr));
                currentSourceBalance = currentSourceAddr.balance;
            }
        }

        return amountMoved;
    }

    /**
     * @dev Get information about multiple vaults
     * @param vaultAddresses Array of vault addresses to get info for
     * @return vaultInfos Array of VaultInfo structs
     */
    function getVaultsInfo(
        address[] memory vaultAddresses
    ) internal view returns (VaultInfo[] memory) {
        VaultInfo[] memory vaultInfos = new VaultInfo[](vaultAddresses.length);

        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            address vaultAddr = vaultAddresses[i];
            Vault vault = Vault(payable(vaultAddr));

            vaultInfos[i] = VaultInfo({
                vaultAddress: vaultAddr,
                owner: vault.owner(),
                ethBalance: vaultAddr.balance,
                isActive: true // Assuming all vaults in the list are active
            });
        }

        return vaultInfos;
    }

    /**
     * @dev Find vaults that match specific criteria
     * @param allVaultAddresses Array of all vault addresses to search through
     * @param minBalance Minimum ETH balance to filter by (0 for no minimum)
     * @param maxBalance Maximum ETH balance to filter by (0 for no maximum)
     * @param owner Owner address to filter by (address(0) for any owner)
     * @param limit Maximum number of results to return (0 for no limit)
     * @return matchingVaults Array of vault addresses that match the criteria
     */
    function findVaultsByCriteria(
        address[] memory allVaultAddresses,
        uint256 minBalance,
        uint256 maxBalance,
        address owner,
        uint256 limit
    ) internal view returns (address[] memory) {
        // Count matching vaults and collect them in a temporary array
        (address[] memory tempResults, uint256 matchCount) = _findMatchingVaults(
            allVaultAddresses,
            minBalance,
            maxBalance,
            owner,
            limit
        );

        // Create result array with exact size
        uint256 resultSize = (limit > 0 && limit < matchCount) ? limit : matchCount;
        address[] memory result = new address[](resultSize);

        // Copy from temp array to final result array
        for (uint256 i = 0; i < resultSize; i++) {
            result[i] = tempResults[i];
        }

        return result;
    }

    /**
     * @dev Helper function to find vaults matching criteria
     * @param allVaultAddresses Array of all vault addresses to search through
     * @param minBalance Minimum ETH balance to filter by
     * @param maxBalance Maximum ETH balance to filter by
     * @param owner Owner address to filter by
     * @param limit Maximum number of results to return
     * @return tempResults Temporary array of matching vault addresses
     * @return matchCount Number of matching vaults found
     */
    function _findMatchingVaults(
        address[] memory allVaultAddresses,
        uint256 minBalance,
        uint256 maxBalance,
        address owner,
        uint256 limit
    ) private view returns (address[] memory tempResults, uint256 matchCount) {
        // Create a temporary array to store matching vaults
        tempResults = new address[](allVaultAddresses.length);
        matchCount = 0;

        // Find matching vaults
        for (uint256 i = 0; i < allVaultAddresses.length; i++) {
            address vaultAddr = allVaultAddresses[i];

            if (_matchesVaultCriteria(vaultAddr, minBalance, maxBalance, owner)) {
                tempResults[matchCount] = vaultAddr;
                matchCount++;

                // Stop if we've reached the limit
                if (limit > 0 && matchCount >= limit) {
                    break;
                }
            }
        }

        return (tempResults, matchCount);
    }

    /**
     * @dev Helper function to check if a vault matches the specified criteria
     * @param vaultAddr Address of the vault to check
     * @param minBalance Minimum ETH balance to filter by (0 for no minimum)
     * @param maxBalance Maximum ETH balance to filter by (0 for no maximum)
     * @param owner Owner address to filter by (address(0) for any owner)
     * @return True if the vault matches all criteria, false otherwise
     */
    function _matchesVaultCriteria(
        address vaultAddr,
        uint256 minBalance,
        uint256 maxBalance,
        address owner
    ) private view returns (bool) {
        // Check balance criteria
        uint256 balance = vaultAddr.balance;
        if (minBalance > 0 && balance < minBalance) return false;
        if (maxBalance > 0 && balance > maxBalance) return false;

        // Check owner criteria
        if (owner != address(0)) {
            Vault vault = Vault(payable(vaultAddr));
            if (vault.owner() != owner) return false;
        }

        return true;
    }
}
