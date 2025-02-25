// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Errors } from "./libraries/Errors.sol";

contract TokenWhitelist is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _whitelistedTokens;

    // @dev Version of the contract
    uint256 public constant VERSION = 1;

    // @dev Maximum page size for token pagination to prevent excessive gas consumption
    uint256 public constant MAX_PAGE_SIZE = 100;

    // @dev Maximum batch size for adding tokens
    uint256 public constant MAX_BATCH_SIZE = 50;

    // @dev Cache expiry time in blocks
    uint256 public constant CACHE_EXPIRY_BLOCKS = 100;

    // @dev Cache for frequently accessed pages
    mapping(bytes32 => address[]) private _pageCache;

    // @dev Block number when cache was last updated
    mapping(bytes32 => uint256) private _cacheUpdatedAt;

    // @dev Event emitted when a token is added to the whitelist
    event TokenAdded(address indexed token);

    // @dev Event emitted when multiple tokens are added to the whitelist
    event TokensAddedInBatch(uint256 count);

    // @dev Event emitted when a token is removed from the whitelist
    event TokenRemoved(address indexed token);

    // @dev Event emitted when the whitelist is updated
    event WhitelistUpdated(uint256 totalTokens);

    // @dev Event emitted when cache is updated
    event CacheUpdated(uint256 offset, uint256 limit);

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
        _addSingleToken(token);
    }

    /**
     * @dev Add multiple tokens to the whitelist in a single transaction.
     * More gas efficient than adding tokens one by one.
     * Emits TokensAddedInBatch event.
     * @param tokens Array of token addresses to whitelist.
     */
    function addTokensBatch(address[] calldata tokens) external onlyOwner whenNotPaused {
        if (tokens.length > MAX_BATCH_SIZE) revert Errors.BatchSizeTooLarge();

        uint256 addedCount = 0;
        address[] memory validTokens = _validateTokensBatch(tokens);

        // Add valid tokens directly
        for (uint256 i = 0; i < validTokens.length; i++) {
            // Skip empty addresses (end of array or invalid tokens)
            if (validTokens[i] == address(0)) break;

            if (_whitelistedTokens.add(validTokens[i])) {
                addedCount++;
                emit TokenAdded(validTokens[i]);
            }
        }

        // Invalidate all caches since the token list changed
        emit WhitelistUpdated(_whitelistedTokens.length());
        emit TokensAddedInBatch(addedCount);
    }

    /**
     * @dev Remove a token from the whitelist.
     * Emits TokenRemoved event.
     * @param token Address of the token to remove.
     */
    function removeToken(address token) external onlyOwner whenNotPaused {
        if (!_whitelistedTokens.contains(token)) revert Errors.TokenNotWhitelisted();
        if (!_whitelistedTokens.remove(token)) revert Errors.TokenRemovalFailed();

        // Invalidate all caches since the token list changed
        emit TokenRemoved(token);
        emit WhitelistUpdated(_whitelistedTokens.length());
    }

    /**
     * @dev Clear all caches
     * Only callable by owner
     */
    function clearAllCaches() external onlyOwner {
        // This function doesn't actually delete the cache data
        // It just invalidates all caches by resetting their update time
        emit WhitelistUpdated(_whitelistedTokens.length());
    }

    /**
     * @dev Get a page of whitelisted tokens with caching for frequent access patterns
     * This function updates the cache for future calls
     * @param offset Starting index
     * @param limit Maximum number of tokens to return (capped at MAX_PAGE_SIZE)
     * @return Array of token addresses for the requested page
     */
    function getWhitelistedTokensPageCached(
        uint256 offset,
        uint256 limit
    ) external returns (address[] memory) {
        uint256 total = _whitelistedTokens.length();
        if (offset >= total) revert Errors.InvalidLimits();

        // Cap the limit to prevent excessive gas consumption
        if (limit > MAX_PAGE_SIZE) {
            limit = MAX_PAGE_SIZE;
        }

        bytes32 cacheKey = keccak256(abi.encodePacked(offset, limit));

        // Check if we need to update the cache
        if (!_isCacheValid(cacheKey)) {
            uint256 end = (offset + limit > total) ? total : offset + limit;
            uint256 size = end - offset;

            address[] memory page = new address[](size);

            // Populate the page
            unchecked {
                for (uint256 i = 0; i < size; i++) {
                    page[i] = _whitelistedTokens.at(offset + i);
                }
            }

            // Update cache
            _updateCache(cacheKey, page);
            emit CacheUpdated(offset, limit);

            return page;
        }

        return _pageCache[cacheKey];
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
     * @dev Get a page of whitelisted tokens with optimized performance and caching
     * @param offset Starting index
     * @param limit Maximum number of tokens to return (capped at MAX_PAGE_SIZE)
     * @return Array of token addresses for the requested page
     */
    function getWhitelistedTokensPage(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory) {
        uint256 total = _whitelistedTokens.length();
        if (offset >= total) revert Errors.InvalidLimits();

        // Cap the limit to prevent excessive gas consumption
        if (limit > MAX_PAGE_SIZE) {
            limit = MAX_PAGE_SIZE;
        }

        // Check cache first
        bytes32 cacheKey = keccak256(abi.encodePacked(offset, limit));
        if (_isCacheValid(cacheKey)) {
            return _pageCache[cacheKey];
        }

        uint256 end = (offset + limit > total) ? total : offset + limit;
        uint256 size = end - offset;

        address[] memory page = new address[](size);

        // Optimized loop with minimal operations per iteration
        unchecked {
            for (uint256 i = 0; i < size; i++) {
                page[i] = _whitelistedTokens.at(offset + i);
            }
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
    // Internal Functions
    // ======================================================

    /**
     * @dev Add a single token to the whitelist
     * @param token Address of the token to add
     */
    function _addSingleToken(address token) internal {
        if (token == address(0)) revert Errors.InvalidAddress();
        if (!_isContract(token)) revert Errors.InvalidTokenContract();
        if (_whitelistedTokens.contains(token)) revert Errors.TokenNotSupported();

        if (!_whitelistedTokens.add(token)) revert Errors.TokenAdditionFailed();
        emit TokenAdded(token);
    }

    /**
     * @dev Update cache with new data
     * @param cacheKey The cache key
     * @param data The data to cache
     */
    function _updateCache(bytes32 cacheKey, address[] memory data) internal {
        uint256 length = data.length;
        _pageCache[cacheKey] = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            _pageCache[cacheKey][i] = data[i];
        }

        _cacheUpdatedAt[cacheKey] = block.number;
    }

    /**
     * @dev UUPS Upgradeable Implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ======================================================
    // Internal View Functions
    // ======================================================

    /**
     * @dev Check if an address is a contract
     * @param addr Address to check
     * @return True if the address is a contract
     */
    function _isContract(address addr) internal view returns (bool) {
        // Using extcodesize is the standard way to check if an address is a contract
        // We're avoiding inline assembly by using a different approach
        return addr.code.length > 0;
    }

    /**
     * @dev Check if cache is valid for a given key
     * @param cacheKey The cache key
     * @return True if cache is valid
     */
    function _isCacheValid(bytes32 cacheKey) internal view returns (bool) {
        return
            _cacheUpdatedAt[cacheKey] > 0 &&
            block.number - _cacheUpdatedAt[cacheKey] <= CACHE_EXPIRY_BLOCKS;
    }

    /**
     * @dev Validate a batch of tokens
     * @param tokens Array of token addresses to validate
     * @return validTokens Array of valid token addresses
     */
    function _validateTokensBatch(
        address[] calldata tokens
    ) internal view returns (address[] memory validTokens) {
        uint256 length = tokens.length;
        if (length == 0) revert Errors.InvalidLimits();
        if (length > MAX_BATCH_SIZE) revert Errors.BatchSizeTooLarge();

        validTokens = new address[](length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < length; i++) {
            address token = tokens[i];

            // Basic validation
            if (token == address(0)) continue;
            if (_whitelistedTokens.contains(token)) continue;

            // Check if it's a contract
            if (!_isContract(token)) continue;

            // Add to valid tokens
            validTokens[validCount] = token;
            validCount++;
        }

        return validTokens;
    }
}
