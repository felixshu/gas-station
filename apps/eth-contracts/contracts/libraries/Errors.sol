// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Errors
 * @dev Library for common errors used across contracts
 */
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
    //@dev Batch size too large
    error BatchSizeTooLarge();
    //@dev Invalid amount
    error InvalidAmount();
    //@dev Invalid parameters
    error InvalidParameters();
    //@dev Update too frequent
    error UpdateTooFrequent();

    // Token related errors
    //@dev Token not supported
    error TokenNotSupported();
    //@dev Token not whitelisted
    error TokenNotWhitelisted();
    //@dev Token addition failed
    error TokenAdditionFailed();
    //@dev Token removal failed
    error TokenRemovalFailed();
    //@dev Invalid token contract (not ERC20 compliant)
    error InvalidTokenContract();

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
    //@dev Not gas station
    error NotGasStation();

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
    //@dev Transfer failed
    error TransferFailed();

    // Emergency related errors
    //@dev Not in emergency mode
    error NotInEmergencyMode();
    //@dev Contract paused
    error ContractPaused();
    //@dev Expected contract to be paused
    error ExpectedPause();

    // Gas optimization related errors
    //@dev Gas price too low
    error GasPriceTooLow();
    //@dev Gas price too high
    error GasPriceTooHigh();
    //@dev EIP-1559 not supported
    error EIP1559NotSupported();
    //@dev Gas optimizer not set
    error GasOptimizerNotSet();
}
