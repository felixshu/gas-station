// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Errors
 * @dev Library for common errors used across contracts
 */
library Errors {
    // Common errors
    //@dev Invalid address
    error InvalidAddress(address addr);
    //@dev Zero amount
    error ZeroAmount();
    //@dev Insufficient balance
    error InsufficientBalance(address account, uint256 available, uint256 required);
    //@dev Invalid limits
    error InvalidLimits(uint256 provided, uint256 max);
    //@dev Unauthorized access
    error UnauthorizedAccess(address caller, address required);
    //@dev Batch size too large
    error BatchSizeTooLarge(uint256 size, uint256 maxSize);
    //@dev Invalid amount
    error InvalidAmount(uint256 amount);
    //@dev Invalid parameters
    error InvalidParameters(string reason);
    //@dev Update too frequent
    error UpdateTooFrequent(uint256 lastUpdate, uint256 currentTime, uint256 minDelay);

    // Token related errors
    //@dev Token not supported
    error TokenNotSupported(address token);
    //@dev Token not whitelisted
    error TokenNotWhitelisted(address token);
    //@dev Token addition failed
    error TokenAdditionFailed(address token);
    //@dev Token removal failed
    error TokenRemovalFailed(address token);
    //@dev Invalid token contract (not ERC20 compliant)
    error InvalidTokenContract(address token);

    // Price feed related errors
    //@dev Invalid ETH price
    error InvalidEthPrice(int256 price);
    //@dev Stale price
    error StalePrice(uint256 timestamp, uint256 currentTime, uint256 maxDelay);
    //@dev Price overflow
    error PriceOverflow(uint256 price);
    //@dev Invalid ETH round ID
    error InvalidEthRoundId(uint80 roundId);

    // Vault related errors
    //@dev Vault not found
    error VaultNotFound();
    //@dev Invalid vault
    error InvalidVault(address vault);
    //@dev Vault balance distribution needed
    error VaultBalanceDistributionNeeded(uint256 totalBalance, uint256 required);
    //@dev Vault limit reached
    error VaultLimitReached(uint256 count, uint256 max);
    //@dev Vault not empty
    error VaultNotEmpty(address vault, uint256 balance);
    //@dev Vault already exists
    error VaultAlreadyExists(address owner, address vault);
    //@dev Proxy creation failed
    error ProxyCreationFailed(address implementation);
    //@dev Max vaults reached
    error MaxVaultsReached(uint256 max);
    //@dev Not gas station
    error NotGasStation(address caller, address gasStation);

    // Transaction related errors
    //@dev Amount below minimum
    error AmountBelowMinimum(uint256 amount, uint256 minimum);
    //@dev Amount above maximum
    error AmountAboveMaximum(uint256 amount, uint256 maximum);
    //@dev Rate limit exceeded
    error RateLimitExceeded(uint256 count, uint256 max);
    //@dev ETH transfer failed
    error EthTransferFailed(address to, uint256 amount);
    //@dev Direct deposit not allowed
    error DirectDepositNotAllowed();
    //@dev Invalid destination
    error InvalidDestination(address destination);
    //@dev Expired deadline
    error ExpiredDeadline(uint256 deadline, uint256 currentTime);
    //@dev Transfer failed
    error TransferFailed(address token, address from, address to, uint256 amount);
    //@dev Invalid signature format or length
    error InvalidSignature(bytes signature);

    // Emergency related errors
    //@dev Not in emergency mode
    error NotInEmergencyMode();
    //@dev Contract paused
    error ContractPaused();
    //@dev Expected contract to be paused
    error ExpectedPause();
}
