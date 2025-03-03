// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IGasStation
 * @dev Interface for the GasStation contract
 */
interface IGasStation {
    // ======================================================
    // Structs
    // ======================================================

    // @dev Initialization parameters
    struct InitParams {
        address defaultToken;
        address defaultPriceFeed;
        uint128 minDepositAmount;
        uint128 maxDepositAmount;
        address vaultFactory;
    }

    // @dev Withdrawal parameters
    struct WithdrawalParams {
        address token;
        uint256 amount;
        address to;
    }

    // @dev Exchange parameters
    struct ExchangeParams {
        address token;
        uint256 amount;
        address destination;
    }

    // @dev Permit parameters
    struct PermitParams {
        ExchangeParams exchange;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // ======================================================
    // Events
    // ======================================================
    /**
     * @dev Emitted when a deposit is processed
     * @param user The user who deposited
     * @param token The token deposited
     * @param tokenAmount The amount of tokens deposited
     * @param ethAmount The amount of ETH sent
     * @param destination The destination address for ETH
     */
    event DepositProcessed(
        address indexed user,
        address indexed token,
        uint256 tokenAmount,
        uint256 ethAmount,
        address destination
    );

    /**
     * @dev Emitted when deposit limits are updated
     * @param minAmount The new minimum deposit amount
     * @param maxAmount The new maximum deposit amount
     */
    event DepositLimitsUpdated(uint128 minAmount, uint128 maxAmount);

    // @dev Limits updated event
    event LimitsUpdated(uint256 minAmount, uint256 maxAmount);

    // @dev Vault factory set event
    event VaultFactorySet(address indexed vaultFactory);

    // @dev Emergency mode enabled event
    event EmergencyModeEnabled();
    // @dev Emergency mode disabled event
    event EmergencyModeDisabled();
    // @dev Emergency withdrawal event
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed to);
    // @dev Payment token updated event
    event PaymentTokenUpdated(address indexed token, uint8 decimals, address priceFeed);
    // @dev Payment token removed event
    event PaymentTokenRemoved(address indexed token);
    // @dev Default token updated event
    event DefaultTokenUpdated(address indexed newDefaultToken);
    // @dev Payment token added event
    event PaymentTokenAdded(address indexed token, address indexed priceFeed);
    // @dev Token exchanged event
    event TokenExchanged(
        address indexed user,
        address indexed token,
        uint256 tokenAmount,
        uint256 ethAmount,
        address indexed destination
    );
    // @dev Rate limit check event
    event RateLimitCheck(uint256 currentBlock, uint256 lastProcessedBlock, uint256 currentDeposits);
    // @dev Rate limit updated event
    event RateLimitUpdated(uint256 blockNumber, uint256 newCount);

    // ======================================================
    // External Functions
    // ======================================================
    // External state-modifying functions
    // @dev Initialize function
    function initialize(InitParams calldata params) external;
    // @dev Set default token function
    function setDefaultToken(address _newDefaultToken) external;
    // @dev Add payment token function
    function addPaymentToken(address token, address priceFeed) external;
    // @dev Remove payment token function
    function removePaymentToken(address token) external;
    // @dev Exchange function
    function exchange(ExchangeParams calldata params) external;
    // @dev Exchange with permit function
    function exchangeWithPermit(PermitParams calldata params) external;
    // @dev Set vault factory function
    function setVaultFactory(address _vaultFactory) external;
    // @dev Set vault gas station function
    function setVaultGasStation(address vault, address gasStation) external;
    // @dev Emergency withdrawal function
    function emergencyWithdrawToken(WithdrawalParams calldata params) external;
    // @dev Enable emergency mode function
    function enableEmergencyMode() external;
    // @dev Disable emergency mode function
    function disableEmergencyMode() external;

    // External view functions
    // @dev Get supported tokens function
    function getSupportedTokens() external view returns (address[] memory);
    // @dev Calculate ETH amount function
    function calculateEthAmount(address token, uint256 amount) external view returns (uint256);
    // @dev Find best vault function
    function findBestVault(
        uint256 requiredEth
    ) external view returns (address vault, uint256 balance);
}
