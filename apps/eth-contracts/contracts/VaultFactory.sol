// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Vault } from "./Vault.sol";
import { IVault } from "./interfaces/IVault.sol";
import { TokenWhitelist } from "./TokenWhitelist.sol";
import { Errors } from "./libraries/Errors.sol";
import { VaultUtils } from "./libraries/VaultUtils.sol";
import { VaultBalancer } from "./libraries/VaultBalancer.sol";

/**
 * @title VaultFactory
 * @dev Factory contract for creating and managing Vault instances
 * @notice This contract uses internal libraries (VaultUtils and VaultBalancer) for complex operations.
 * Internal libraries are included in the contract bytecode and don't require the unsafeAllowLinkedLibraries flag.
 */
contract VaultFactory is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using VaultUtils for address[];
    using VaultBalancer for address[];

    /// @dev ProxyAdmin for managing vault proxies
    ProxyAdmin public proxyAdmin;

    /// @dev Implementation contract for vaults
    address public vaultImplementation;

    /// @dev TokenWhitelist contract used by all vaults
    TokenWhitelist public tokenWhitelist;

    /// @dev Set to store all vault addresses
    EnumerableSet.AddressSet private _allVaults;

    /// @dev Mapping of owner to their vaults
    mapping(address => EnumerableSet.AddressSet) private _ownerVaults;

    /// Events
    // @dev Vault created event
    event VaultCreated(address indexed owner, address indexed vault);
    // @dev Implementation updated event
    event ImplementationUpdated(address indexed newImplementation);
    // @dev Whitelist updated event
    event WhitelistUpdated(address indexed newWhitelist);
    // @dev Proxy admin created event
    event ProxyAdminCreated(address indexed admin);
    // @dev Vault GasStation updated event
    event VaultGasStationUpdated(address indexed vault, address indexed newGasStation);
    // @dev Vault retired event
    event VaultRetired(address indexed oldVault, address indexed newVault);
    // @dev Vault TokenWhitelist updated event
    event VaultWhitelistUpdated(address indexed vault, address indexed newWhitelist);
    // @dev Vault ownership transferred event
    event VaultOwnershipTransferred(
        address indexed vault,
        address indexed previousOwner,
        address indexed newOwner
    );
    // @dev Event emitted when ETH is balanced between vaults
    event EthBalanced(address indexed sourceVault, address indexed targetVault, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     * @param _vaultImplementation Address of the vault implementation
     * @param _tokenWhitelist Address of the token whitelist
     */
    function initialize(address _vaultImplementation, address _tokenWhitelist) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();

        if (_vaultImplementation == address(0)) revert Errors.InvalidAddress(_vaultImplementation);
        if (_tokenWhitelist == address(0)) revert Errors.InvalidAddress(_tokenWhitelist);

        proxyAdmin = new ProxyAdmin(msg.sender);
        vaultImplementation = _vaultImplementation;
        tokenWhitelist = TokenWhitelist(_tokenWhitelist);

        emit ProxyAdminCreated(address(proxyAdmin));
    }

    /**
     * @dev Create a new vault as a TransparentUpgradeableProxy
     * @param vaultOwner Address that will own the vault
     * @return vault Address of the new vault
     */
    function createVault(
        address vaultOwner
    ) external nonReentrant whenNotPaused onlyOwner returns (address vault) {
        if (vaultImplementation == address(0)) revert Errors.InvalidVault(vaultImplementation);
        if (address(tokenWhitelist) == address(0))
            revert Errors.TokenNotWhitelisted(address(tokenWhitelist));
        if (vaultOwner == address(0)) revert Errors.InvalidAddress(vaultOwner);

        // Initialize vault with owner and configuration
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            IVault.InitParams({ owner: vaultOwner, whitelist: address(tokenWhitelist) })
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            vaultImplementation,
            address(proxyAdmin),
            initData
        );

        vault = address(proxy);

        if (vault == address(0)) revert Errors.ProxyCreationFailed(vaultImplementation);

        // Record the new vault
        if (!_allVaults.add(vault)) revert Errors.ProxyCreationFailed(vaultImplementation);
        if (!_ownerVaults[vaultOwner].add(vault))
            revert Errors.ProxyCreationFailed(vaultImplementation);

        emit VaultCreated(vaultOwner, vault);
    }

    /**
     * @dev Create multiple vaults in a single transaction
     * @param vaultOwners Array of addresses that will own the vaults
     * @return vaults Array of addresses of the new vaults
     */
    function createMultipleVaults(
        address[] calldata vaultOwners
    ) external nonReentrant whenNotPaused onlyOwner returns (address[] memory vaults) {
        if (vaultImplementation == address(0)) revert Errors.InvalidVault(vaultImplementation);
        if (address(tokenWhitelist) == address(0))
            revert Errors.TokenNotWhitelisted(address(tokenWhitelist));

        uint256 length = vaultOwners.length;
        vaults = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            address vaultOwner = vaultOwners[i];
            if (vaultOwner == address(0)) revert Errors.InvalidAddress(vaultOwner);

            // Create a single vault using the helper function
            vaults[i] = _createSingleVault(vaultOwner);
        }
    }

    /**
     * @dev Helper function to create a single vault
     * @param vaultOwner Address that will own the vault
     * @return vault Address of the new vault
     */
    function _createSingleVault(address vaultOwner) private returns (address vault) {
        // Initialize vault with owner and configuration
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            IVault.InitParams({ owner: vaultOwner, whitelist: address(tokenWhitelist) })
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            vaultImplementation,
            address(proxyAdmin),
            initData
        );

        vault = address(proxy);

        if (vault == address(0)) revert Errors.ProxyCreationFailed(vaultImplementation);

        // Record the new vault
        if (!_allVaults.add(vault)) revert Errors.ProxyCreationFailed(vaultImplementation);
        if (!_ownerVaults[vaultOwner].add(vault))
            revert Errors.ProxyCreationFailed(vaultImplementation);

        emit VaultCreated(vaultOwner, vault);
    }

    /**
     * @dev Update the vault implementation address
     * @param _newImplementation Address of the new implementation
     */
    function updateImplementation(address _newImplementation) external onlyOwner whenNotPaused {
        if (_newImplementation == address(0)) revert Errors.InvalidAddress(_newImplementation);
        vaultImplementation = _newImplementation;
        emit ImplementationUpdated(_newImplementation);
    }

    /**
     * @dev Update the token whitelist
     * @param _newWhitelist Address of the new whitelist
     */
    function updateWhitelist(address _newWhitelist) external onlyOwner whenNotPaused {
        if (_newWhitelist == address(0)) revert Errors.InvalidAddress(_newWhitelist);
        tokenWhitelist = TokenWhitelist(_newWhitelist);
        emit WhitelistUpdated(_newWhitelist);
    }

    /**
     * @dev Get the number of vaults owned by a specific owner
     * @param vaultOwner Address of the vault owner
     * @return Number of vaults
     */
    function getVaultCountByOwner(address vaultOwner) external view returns (uint256) {
        return _ownerVaults[vaultOwner].length();
    }

    /**
     * @dev Get a specific vault by owner and index
     * @param vaultOwner Address of the vault owner
     * @param index Index of the vault in the owner's vault list
     * @return Address of the vault
     */
    function getVaultByOwnerAndIndex(
        address vaultOwner,
        uint256 index
    ) external view returns (address) {
        if (index >= _ownerVaults[vaultOwner].length())
            revert Errors.InvalidLimits(index, _ownerVaults[vaultOwner].length());
        return _ownerVaults[vaultOwner].at(index);
    }

    /**
     * @dev Get the last vault created by an owner
     * @param vaultOwner Address of the vault owner
     * @return Address of the last vault, address(0) if no vaults exist
     */
    function getLastVaultByOwner(address vaultOwner) external view returns (address) {
        uint256 length = _ownerVaults[vaultOwner].length();
        if (length == 0) return address(0);
        return _ownerVaults[vaultOwner].at(length - 1);
    }

    /**
     * @dev Get all vaults created by this factory
     * @return Array of all vault addresses
     */
    function getAllVaults() external view returns (address[] memory) {
        uint256 length = _allVaults.length();
        address[] memory vaults = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            vaults[i] = _allVaults.at(i);
        }
        return vaults;
    }

    /**
     * @dev Get all vaults (internal version)
     * @return Array of all vault addresses
     */
    function _getAllVaults() private view returns (address[] memory) {
        return _allVaults.values();
    }

    /**
     * @dev Check if an address is a valid vault created by this factory
     * @param vault Address to check
     * @return bool True if the address is a valid vault
     */
    function isVault(address vault) external view returns (bool) {
        return _allVaults.contains(vault);
    }

    /**
     * @dev Get the number of vaults created by this factory
     * @return Number of vaults
     */
    function getVaultCount() external view returns (uint256) {
        return _allVaults.length();
    }

    function getVaultsByOwner(address vaultOwner) external view returns (address[] memory) {
        return _ownerVaults[vaultOwner].values();
    }

    /**
     * @dev Get information about multiple vaults
     * @param vaultAddresses Array of vault addresses to get info for
     * @return vaultInfos Array of VaultInfo structs
     */
    function getVaultsInfo(
        address[] calldata vaultAddresses
    ) external view returns (VaultUtils.VaultInfo[] memory) {
        return VaultUtils.getVaultsInfo(vaultAddresses);
    }

    /**
     * @dev Find vaults that match specific criteria
     * @param minBalance Minimum ETH balance to filter by (0 for no minimum)
     * @param maxBalance Maximum ETH balance to filter by (0 for no maximum)
     * @param owner Owner address to filter by (address(0) for any owner)
     * @param limit Maximum number of results to return (0 for no limit)
     * @return matchingVaults Array of vault addresses that match the criteria
     */
    function findVaultsByCriteria(
        uint256 minBalance,
        uint256 maxBalance,
        address owner,
        uint256 limit
    ) external view returns (address[] memory) {
        address[] memory allVaultAddresses = _getAllVaults();
        return
            VaultUtils.findVaultsByCriteria(
                allVaultAddresses,
                minBalance,
                maxBalance,
                owner,
                limit
            );
    }

    /**
     * @dev Mark a vault as retired and optionally migrate its ETH to a new vault
     * @param oldVault Address of the vault to retire
     * @param newVault Address of the new vault to migrate funds to (optional, can be address(0))
     * @param migrateEth Whether to migrate ETH from old vault to new vault
     */
    function retireVault(
        address oldVault,
        address newVault,
        bool migrateEth
    ) external nonReentrant onlyOwner {
        if (!_allVaults.contains(oldVault)) revert Errors.InvalidVault(oldVault);

        Vault vault = Vault(payable(oldVault));

        // Pause the old vault to prevent new deposits
        if (!vault.paused()) {
            try vault.emergencyPause() {
                // Successfully paused
            } catch {
                // If pause fails, continue with the rest of the function
            }
        }

        // If a new vault is specified and migration is requested
        if (newVault != address(0) && migrateEth) {
            if (!_allVaults.contains(newVault)) revert Errors.InvalidVault(newVault);

            // Get the ETH balance of the old vault
            uint256 ethBalance = oldVault.balance;

            if (ethBalance > 0) {
                // Transfer ETH from old vault to new vault
                vault.sendEth(IVault.EthParams({ amount: ethBalance, recipient: newVault }));
            }
        }

        // Mark the vault as retired (we keep it in _allVaults for record-keeping)
        emit VaultRetired(oldVault, newVault);
    }

    /**
     * @dev Update the TokenWhitelist for multiple vaults at once
     * @param vaults Array of vault addresses to update
     * @param newWhitelist New TokenWhitelist address
     * @return successCount Number of vaults successfully updated
     */
    function batchUpdateTokenWhitelist(
        address[] calldata vaults,
        address newWhitelist
    ) external onlyOwner returns (uint256 successCount) {
        if (newWhitelist == address(0)) revert Errors.InvalidAddress(newWhitelist);

        // Verify the new whitelist is valid
        TokenWhitelist whitelist = TokenWhitelist(newWhitelist);
        // Try to call a function on the whitelist to verify it's a valid contract
        try whitelist.owner() returns (address) {
            // Valid whitelist contract
        } catch {
            revert Errors.InvalidAddress(address(0));
        }

        successCount = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            address vaultAddr = vaults[i];
            if (_allVaults.contains(vaultAddr)) {
                Vault vault = Vault(payable(vaultAddr));
                // Only update if the caller is the owner of the VaultFactory
                try vault.setTokenWhitelist(newWhitelist) {
                    successCount++;
                    emit VaultWhitelistUpdated(vaultAddr, newWhitelist);
                } catch {
                    // Continue with the next vault if this one fails
                }
            }
        }
    }

    /**
     * @dev Transfer ownership of multiple vaults at once
     * @param vaults Array of vault addresses to transfer
     * @param newOwner New owner address
     * @return successCount Number of vaults successfully transferred
     */
    function batchTransferVaultOwnership(
        address[] calldata vaults,
        address newOwner
    ) external onlyOwner returns (uint256 successCount) {
        if (newOwner == address(0)) revert Errors.InvalidAddress(address(0));

        successCount = 0;
        for (uint256 i = 0; i < vaults.length; i++) {
            address vaultAddr = vaults[i];
            if (_allVaults.contains(vaultAddr)) {
                if (_transferVaultOwnership(vaultAddr, newOwner)) {
                    successCount++;
                }
            }
        }
    }

    /**
     * @dev Helper function to transfer ownership of a single vault
     * @param vaultAddr Address of the vault to transfer
     * @param newOwner New owner address
     * @return success Whether the transfer was successful
     */
    function _transferVaultOwnership(
        address vaultAddr,
        address newOwner
    ) private returns (bool success) {
        Vault vault = Vault(payable(vaultAddr));

        // Get current owner to update our records
        address currentOwner;
        try vault.owner() returns (address vaultOwnerAddr) {
            currentOwner = vaultOwnerAddr;
        } catch {
            return false; // Skip if we can't get the owner
        }

        // Transfer ownership
        try vault.transferOwnership(newOwner) {
            // Update our internal records
            if (_ownerVaults[currentOwner].contains(vaultAddr)) {
                _ownerVaults[currentOwner].remove(vaultAddr);
            }

            if (!_ownerVaults[newOwner].add(vaultAddr)) {
                // If adding to new owner fails, try to add back to old owner
                _ownerVaults[currentOwner].add(vaultAddr);
                return false;
            }

            emit VaultOwnershipTransferred(vaultAddr, currentOwner, newOwner);
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @dev Auto-balance ETH across vaults based on thresholds
     * @param lowerThreshold Minimum ETH balance threshold
     * @param upperThreshold Maximum ETH balance threshold
     * @param targetEthBalance Target ETH balance for vaults below threshold
     * @return totalMoved Total amount of ETH moved between vaults
     */
    function autoBalanceEthAcrossVaults(
        uint256 lowerThreshold,
        uint256 upperThreshold,
        uint256 targetEthBalance
    ) external nonReentrant onlyOwner returns (uint256) {
        address[] memory allVaultAddresses = _getAllVaults();

        // Find vaults that need balancing
        (
            address[] memory sourceVaults,
            address[] memory targetVaults,
            uint256[] memory targetBalances
        ) = VaultBalancer.findVaultsForBalancing(
                allVaultAddresses,
                lowerThreshold,
                upperThreshold,
                targetEthBalance
            );

        // If no vaults need balancing, return 0
        if (sourceVaults.length == 0 || targetVaults.length == 0) {
            return 0;
        }

        // Call the manual balance function with our identified vaults
        return this.balanceEthAcrossVaults(sourceVaults, targetVaults, targetBalances);
    }

    /**
     * @dev Balance ETH across vaults to optimize distribution
     * @param sourceVaults Array of vault addresses with excess ETH
     * @param targetVaults Array of vault addresses that need more ETH
     * @param targetBalances Array of target ETH balances for each target vault
     * @return totalMoved Total amount of ETH moved between vaults
     */
    function balanceEthAcrossVaults(
        address[] calldata sourceVaults,
        address[] calldata targetVaults,
        uint256[] calldata targetBalances
    ) external nonReentrant onlyOwner returns (uint256 totalMoved) {
        // Validate inputs using helper function
        _validateBalanceInputs(sourceVaults, targetVaults, targetBalances);

        // Calculate ETH distribution
        (
            uint256 totalEthNeeded,
            uint256 totalAvailableEth,
            uint256[] memory currentBalances
        ) = VaultBalancer.calculateEthDistribution(sourceVaults, targetVaults, targetBalances);

        // If no ETH is needed, return early
        if (totalEthNeeded == 0) return 0;

        // If not enough ETH is available, revert
        if (totalAvailableEth < totalEthNeeded)
            revert Errors.InsufficientBalance(address(this), totalAvailableEth, totalEthNeeded);

        // Start moving ETH from source to target vaults
        totalMoved = VaultUtils.moveEthBetweenVaults(
            sourceVaults,
            targetVaults,
            targetBalances,
            currentBalances
        );

        // Emit events for successful transfers
        _emitEthBalancedEvents(sourceVaults, targetVaults, targetBalances, currentBalances);

        return totalMoved;
    }

    /**
     * @dev Helper function to validate inputs for balanceEthAcrossVaults
     * @param sourceVaults Array of vault addresses with excess ETH
     * @param targetVaults Array of vault addresses that need more ETH
     * @param targetBalances Array of target ETH balances for each target vault
     */
    function _validateBalanceInputs(
        address[] calldata sourceVaults,
        address[] calldata targetVaults,
        uint256[] calldata targetBalances
    ) private view {
        // Validate input array lengths
        if (targetVaults.length != targetBalances.length)
            revert Errors.InvalidLimits(targetVaults.length, targetBalances.length);
        if (sourceVaults.length == 0 || targetVaults.length == 0) revert Errors.InvalidLimits(0, 1);

        // Validate that all source vaults exist in our registry
        for (uint256 i = 0; i < sourceVaults.length; i++) {
            if (!_allVaults.contains(sourceVaults[i])) revert Errors.InvalidVault(sourceVaults[i]);
        }

        // Validate that all target vaults exist in our registry
        for (uint256 i = 0; i < targetVaults.length; i++) {
            if (!_allVaults.contains(targetVaults[i])) revert Errors.InvalidVault(targetVaults[i]);
        }
    }

    /**
     * @dev Helper function to emit EthBalanced events for successful transfers
     * @param sourceVaults Array of vault addresses with excess ETH
     * @param targetVaults Array of vault addresses that need more ETH
     * @param targetBalances Array of target ETH balances for each target vault
     * @param currentBalances Array of current ETH balances for each target vault
     */
    function _emitEthBalancedEvents(
        address[] calldata sourceVaults,
        address[] calldata targetVaults,
        uint256[] calldata targetBalances,
        uint256[] memory currentBalances
    ) private {
        for (uint256 i = 0; i < sourceVaults.length; i++) {
            for (uint256 j = 0; j < targetVaults.length; j++) {
                if (currentBalances[j] < targetBalances[j]) {
                    uint256 moved = targetBalances[j] - currentBalances[j] > 0
                        ? targetBalances[j] - currentBalances[j]
                        : 0;
                    if (moved > 0) {
                        emit EthBalanced(sourceVaults[i], targetVaults[j], moved);
                    }
                }
            }
        }
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     * Called by {upgradeTo} and {upgradeToAndCall}.
     * @param newImplementation address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
