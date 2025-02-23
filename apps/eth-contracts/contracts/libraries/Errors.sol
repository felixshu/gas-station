// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Errors {
    // Common errors
    //@dev Invalid address
    error InvalidAddress();
    //@dev Zero amount
    error ZeroAmount();
    //@dev Insufficient balance
    error InsufficientBalance();
    //@dev Invalid limits
    error InvalidLimits();
    //@dev Unauthorized access
    error UnauthorizedAccess();

    // Token related errors
    //@dev Token not supported
    error TokenNotSupported();
    //@dev Token not whitelisted
    error TokenNotWhitelisted();
    //@dev Token addition failed
    error TokenAdditionFailed();
    //@dev Token removal failed
    error TokenRemovalFailed();

    // Price feed related errors
    //@dev Invalid ETH price
    error InvalidEthPrice();
    //@dev Stale price
    error StalePrice();
    //@dev Price overflow
    error PriceOverflow();
    //@dev Invalid ETH round ID
    error InvalidEthRoundId();

    // Vault related errors
    //@dev Vault not found
    error VaultNotFound();
    //@dev Invalid vault
    error InvalidVault();
    //@dev Vault balance distribution needed
    error VaultBalanceDistributionNeeded();
    //@dev Vault limit reached
    error VaultLimitReached();
    //@dev Vault not empty
    error VaultNotEmpty();
    //@dev Vault already exists
    error VaultAlreadyExists();
    //@dev Proxy creation failed
    error ProxyCreationFailed();
    //@dev Max vaults reached
    error MaxVaultsReached();

    // Transaction related errors
    //@dev Amount below minimum
    error AmountBelowMinimum();
    //@dev Amount above maximum
    error AmountAboveMaximum();
    //@dev Rate limit exceeded
    error RateLimitExceeded();
    //@dev ETH transfer failed
    error EthTransferFailed();
    //@dev Direct deposit not allowed
    error DirectDepositNotAllowed();
    //@dev Invalid destination
    error InvalidDestination();
    //@dev Expired deadline
    error ExpiredDeadline();

    // Emergency related errors
    //@dev Not in emergency mode
    error NotInEmergencyMode();
    //@dev Contract paused
    error ContractPaused();
}
