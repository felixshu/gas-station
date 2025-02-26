// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ITokenWhitelist
 * @dev Interface for the TokenWhitelist contract
 */
interface ITokenWhitelist {
    /**
     * @dev Event emitted when a token is added to the whitelist
     */
    event TokenAdded(address indexed token);

    /**
     * @dev Event emitted when multiple tokens are added to the whitelist
     */
    event TokensAddedInBatch(uint256 count);

    /**
     * @dev Event emitted when a token is removed from the whitelist
     */
    event TokenRemoved(address indexed token);

    /**
     * @dev Event emitted when the whitelist is updated
     */
    event WhitelistUpdated(uint256 totalTokens);

    /**
     * @dev Event emitted when cache is updated
     */
    event CacheUpdated(uint256 offset, uint256 limit);

    /**
     * @dev Check if a token is whitelisted
     * @param token The token address to check
     * @return bool True if the token is whitelisted
     */
    function isTokenWhitelisted(address token) external view returns (bool);

    /**
     * @dev Add a token to the whitelist
     * @param token The token address to add
     */
    function addToken(address token) external;

    /**
     * @dev Remove a token from the whitelist
     * @param token The token address to remove
     */
    function removeToken(address token) external;
}
