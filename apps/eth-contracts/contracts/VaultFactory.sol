// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Vault } from "./Vault.sol";
import { IVault } from "./interfaces/IVault.sol";
import { TokenWhitelist } from "./TokenWhitelist.sol";
import { Errors } from "./libraries/Errors.sol";

contract VaultFactory is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

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

        if (_vaultImplementation == address(0)) revert Errors.InvalidAddress();
        if (_tokenWhitelist == address(0)) revert Errors.InvalidAddress();

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
        if (vaultImplementation == address(0)) revert Errors.InvalidVault();
        if (address(tokenWhitelist) == address(0)) revert Errors.TokenNotWhitelisted();
        if (vaultOwner == address(0)) revert Errors.InvalidAddress();

        // Initialize vault with owner and configuration
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            vaultOwner,
            address(tokenWhitelist)
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            vaultImplementation,
            address(proxyAdmin),
            initData
        );

        vault = address(proxy);

        if (vault == address(0)) revert Errors.ProxyCreationFailed();

        // Record the new vault
        if (!_allVaults.add(vault)) revert Errors.ProxyCreationFailed();
        if (!_ownerVaults[vaultOwner].add(vault)) revert Errors.ProxyCreationFailed();

        emit VaultCreated(vaultOwner, vault);
    }

    /**
     * @dev Update the vault implementation address
     * @param _newImplementation Address of the new implementation
     */
    function updateImplementation(address _newImplementation) external onlyOwner whenNotPaused {
        if (_newImplementation == address(0)) revert Errors.InvalidAddress();
        vaultImplementation = _newImplementation;
        emit ImplementationUpdated(_newImplementation);
    }

    /**
     * @dev Update the token whitelist
     * @param _newWhitelist Address of the new whitelist
     */
    function updateWhitelist(address _newWhitelist) external onlyOwner whenNotPaused {
        if (_newWhitelist == address(0)) revert Errors.InvalidAddress();
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
        if (index >= _ownerVaults[vaultOwner].length()) revert Errors.InvalidLimits();
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
}
