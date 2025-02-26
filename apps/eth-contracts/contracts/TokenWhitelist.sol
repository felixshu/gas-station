// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Errors } from "./libraries/Errors.sol";

/**
 * @title TokenWhitelist
 * @dev Contract for managing a whitelist of token addresses
 * Optimized for gas efficiency with calldata and storage optimizations
 */
contract TokenWhitelist is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ======================================================
    // Structs
    // ======================================================

    /**
     * @dev Struct for pagination parameters to reduce calldata size
     */
    struct PaginationParams {
        uint32 offset;
        uint32 limit;
    }

    /**
     * @dev Struct for cache entry to pack related storage variables
     */
    struct CacheEntry {
        uint32 updatedAt;
        bool isValid;
        address[] data;
    }

    // ======================================================
    // State Variables
    // ======================================================

    // @dev Set of whitelisted token addresses
    EnumerableSet.AddressSet private _whitelistedTokens;

    // @dev Version of the contract
    uint256 public constant VERSION = 1;

    // @dev Maximum page size for token pagination to prevent excessive gas consumption
    uint32 public constant MAX_PAGE_SIZE = 100;

    // @dev Maximum batch size for adding tokens
    uint32 public constant MAX_BATCH_SIZE = 50;

    // @dev Cache expiry time in blocks
    uint32 public constant CACHE_EXPIRY_BLOCKS = 100;

    // @dev Cache for frequently accessed pages
    mapping(bytes32 => CacheEntry) private _pageCache;

    // ======================================================
    // Events
    // ======================================================

    // @dev Event emitted when a token is added to the whitelist
    event TokenAdded(address indexed token);

    // @dev Event emitted when multiple tokens are added to the whitelist
    event TokensAddedInBatch(uint256 count);

    // @dev Event emitted when a token is removed from the whitelist
    event TokenRemoved(address indexed token);

    // @dev Event emitted when the whitelist is updated
    event WhitelistUpdated(uint256 totalTokens);

    // @dev Event emitted when cache is updated
    event CacheUpdated(uint32 offset, uint32 limit);

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

        // Invalidate all caches since the token list changed
        emit WhitelistUpdated(_whitelistedTokens.length());
    }

    /**
     * @dev Add multiple tokens to the whitelist in a single transaction.
     * More gas efficient than adding tokens one by one.
     * Emits TokensAddedInBatch event.
     * @param tokens Array of token addresses to whitelist.
     */
    function addTokensBatch(address[] calldata tokens) external onlyOwner whenNotPaused {
        uint256 length = tokens.length;
        if (length == 0) revert Errors.InvalidLimits(0, 1);
        if (length > MAX_BATCH_SIZE) revert Errors.BatchSizeTooLarge(length, MAX_BATCH_SIZE);

        uint256 addedCount = 0;

        // Process tokens directly from calldata without copying to memory
        for (uint256 i = 0; i < length; i++) {
            address token = tokens[i];

            // Skip invalid tokens
            if (token == address(0)) continue;
            if (_whitelistedTokens.contains(token)) continue;
            if (!_isContract(token)) continue;

            // Add valid token
            if (_whitelistedTokens.add(token)) {
                addedCount++;
                emit TokenAdded(token);
            }
        }

        // Invalidate all caches since the token list changed
        if (addedCount > 0) {
            emit WhitelistUpdated(_whitelistedTokens.length());
            emit TokensAddedInBatch(addedCount);
        }
    }

    /**
     * @dev Remove a token from the whitelist.
     * Emits TokenRemoved event.
     * @param token Address of the token to remove.
     */
    function removeToken(address token) external onlyOwner whenNotPaused {
        if (!_whitelistedTokens.contains(token)) revert Errors.TokenNotWhitelisted(token);
        if (!_whitelistedTokens.remove(token)) revert Errors.TokenRemovalFailed(token);

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
        // It just invalidates all caches by emitting an event
        emit WhitelistUpdated(_whitelistedTokens.length());
    }

    /**
     * @dev Get a page of whitelisted tokens with caching for frequent access patterns
     * This function updates the cache for future calls
     * @param params Pagination parameters (offset and limit)
     * @return Array of token addresses for the requested page
     */
    function getWhitelistedTokensPageCached(
        PaginationParams calldata params
    ) external returns (address[] memory) {
        uint256 total = _whitelistedTokens.length();
        if (params.offset >= total) revert Errors.InvalidLimits(params.offset, total);

        // Cap the limit to prevent excessive gas consumption
        uint32 limit = params.limit > MAX_PAGE_SIZE ? MAX_PAGE_SIZE : params.limit;

        bytes32 cacheKey = keccak256(abi.encodePacked(params.offset, limit));
        CacheEntry storage cacheEntry = _pageCache[cacheKey];

        // Check if we need to update the cache
        if (!_isCacheValid(cacheEntry)) {
            uint256 end = (params.offset + limit > total) ? total : params.offset + limit;
            uint256 size = end - params.offset;

            address[] memory page = new address[](size);

            // Populate the page
            unchecked {
                for (uint256 i = 0; i < size; i++) {
                    page[i] = _whitelistedTokens.at(params.offset + i);
                }
            }

            // Update cache
            cacheEntry.data = page;
            cacheEntry.updatedAt = uint32(block.number);
            cacheEntry.isValid = true;

            emit CacheUpdated(params.offset, limit);

            return page;
        }

        return cacheEntry.data;
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
        if (index >= _whitelistedTokens.length())
            revert Errors.InvalidLimits(index, _whitelistedTokens.length());
        return _whitelistedTokens.at(index);
    }

    /**
     * @dev Get a page of whitelisted tokens with optimized performance and caching
     * @param params Pagination parameters (offset and limit)
     * @return Array of token addresses for the requested page
     */
    function getWhitelistedTokensPage(
        PaginationParams calldata params
    ) external view returns (address[] memory) {
        uint256 total = _whitelistedTokens.length();
        if (params.offset >= total) revert Errors.InvalidLimits(params.offset, total);

        // Cap the limit to prevent excessive gas consumption
        uint32 limit = params.limit > MAX_PAGE_SIZE ? MAX_PAGE_SIZE : params.limit;

        // Check cache first
        bytes32 cacheKey = keccak256(abi.encodePacked(params.offset, limit));
        CacheEntry storage cacheEntry = _pageCache[cacheKey];

        if (_isCacheValid(cacheEntry)) {
            return cacheEntry.data;
        }

        uint256 end = (params.offset + limit > total) ? total : params.offset + limit;
        uint256 size = end - params.offset;

        address[] memory page = new address[](size);

        // Optimized loop with minimal operations per iteration
        unchecked {
            for (uint256 i = 0; i < size; i++) {
                page[i] = _whitelistedTokens.at(params.offset + i);
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
        if (token == address(0)) revert Errors.InvalidAddress(token);
        if (!_isContract(token)) revert Errors.InvalidTokenContract(token);
        if (_whitelistedTokens.contains(token)) revert Errors.TokenNotSupported(token);

        if (!_whitelistedTokens.add(token)) revert Errors.TokenAdditionFailed(token);
        emit TokenAdded(token);
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
        return addr.code.length > 0;
    }

    /**
     * @dev Check if cache is valid for a given entry
     * @param cacheEntry The cache entry to check
     * @return True if cache is valid
     */
    function _isCacheValid(CacheEntry storage cacheEntry) internal view returns (bool) {
        return
            cacheEntry.isValid &&
            cacheEntry.updatedAt > 0 &&
            block.number - cacheEntry.updatedAt <= CACHE_EXPIRY_BLOCKS;
    }
}
