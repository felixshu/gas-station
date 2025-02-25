// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Errors } from "./libraries/Errors.sol";

contract TokenWhitelist is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _whitelistedTokens;

    // @dev Version of the contract
    uint256 public constant VERSION = 1;

    // @dev Event emitted when a token is added to the whitelist
    event TokenAdded(address indexed token);

    // @dev Event emitted when a token is removed from the whitelist
    event TokenRemoved(address indexed token);

    // @dev Event emitted when the whitelist is updated
    event WhitelistUpdated(uint256 totalTokens);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __Pausable_init();
    }

    /**
     * @dev Add a new token to the whitelist.
     * Emits TokenAdded event.
     * @param token Address of the token to whitelist.
     */
    function addToken(address token) external onlyOwner whenNotPaused {
        if (token == address(0)) revert Errors.InvalidAddress();
        if (_whitelistedTokens.contains(token)) revert Errors.TokenNotSupported();

        // Verify the token address is a contract by checking if it has code
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(token)
        }
        if (codeSize == 0) revert Errors.InvalidTokenContract();

        // Verify the token implements the ERC20 interface
        // We'll try to call totalSupply() which is a view function that all ERC20 tokens must implement
        try IERC20(token).totalSupply() {
            // If the call succeeds, the token likely implements ERC20
        } catch {
            // If the call fails, the token doesn't implement ERC20 correctly
            revert Errors.InvalidTokenContract();
        }

        if (!_whitelistedTokens.add(token)) revert Errors.TokenAdditionFailed();
        emit TokenAdded(token);
    }

    /**
     * @dev Remove a token from the whitelist.
     * Emits TokenRemoved event.
     * @param token Address of the token to remove.
     */
    function removeToken(address token) external onlyOwner whenNotPaused {
        if (!_whitelistedTokens.contains(token)) revert Errors.TokenNotWhitelisted();
        if (!_whitelistedTokens.remove(token)) revert Errors.TokenRemovalFailed();
        emit TokenRemoved(token);
    }

    /**
     * @dev Get total number of whitelisted tokens
     * @return Number of whitelisted tokens
     */
    function getWhitelistedTokenCount() external view returns (uint256) {
        return _whitelistedTokens.length();
    }

    /**
     * @dev Get whitelisted token by index
     * @param index Index of the token in the set
     * @return Address of the token
     */
    function getWhitelistedTokenAt(uint256 index) external view returns (address) {
        if (index >= _whitelistedTokens.length()) revert Errors.InvalidLimits();
        return _whitelistedTokens.at(index);
    }

    /**
     * @dev Get a page of whitelisted tokens
     * @param offset Starting index
     * @param limit Maximum number of tokens to return
     * @return Array of token addresses for the requested page
     */
    function getWhitelistedTokensPage(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory) {
        uint256 total = _whitelistedTokens.length();
        if (offset >= total) revert Errors.InvalidLimits();

        uint256 end = (offset + limit > total) ? total : offset + limit;
        uint256 size = end - offset;

        address[] memory page = new address[](size);
        for (uint256 i = 0; i < size; i++) {
            page[i] = _whitelistedTokens.at(offset + i);
        }
        return page;
    }

    /**
     * @dev Check if a token is whitelisted.
     * @param token Address of the token to check.
     * @return True if the token is whitelisted, false otherwise.
     */
    function isTokenWhitelisted(address token) external view returns (bool) {
        return _whitelistedTokens.contains(token);
    }

    // ======================================================
    // UUPS Upgradeable Implementation
    // ======================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
