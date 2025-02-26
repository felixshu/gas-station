// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IGasStation
 * @dev Interface for the GasStation contract
 */
interface IGasStation {
    // ======================================================
    // Events
    // ======================================================
    event DepositProcessed(
        address indexed depositor,
        address indexed destination,
        address indexed token,
        uint256 amount,
        uint256 ethAmount
    );
    event LimitsUpdated(uint256 minAmount, uint256 maxAmount);
    event VaultFactorySet(address indexed vaultFactory);
    event EmergencyModeEnabled();
    event EmergencyModeDisabled();
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed to);
    event PaymentTokenUpdated(address indexed token, uint8 decimals, address priceFeed);
    event PaymentTokenRemoved(address indexed token);
    event DefaultTokenUpdated(address indexed newDefaultToken);
    event PaymentTokenAdded(address indexed token, address indexed priceFeed);
    event TokenExchanged(
        address indexed user,
        address indexed token,
        uint256 tokenAmount,
        uint256 ethAmount,
        address indexed destination
    );
    event RateLimitCheck(uint256 currentBlock, uint256 lastProcessedBlock, uint256 currentDeposits);
    event RateLimitUpdated(uint256 blockNumber, uint256 newCount);

    // ======================================================
    // Structs
    // ======================================================
    struct InitParams {
        address defaultToken;
        address defaultPriceFeed;
        uint128 minDepositAmount;
        uint128 maxDepositAmount;
        address vaultFactory;
    }

    struct WithdrawalParams {
        address token;
        uint256 amount;
        address to;
    }

    struct ExchangeParams {
        address token;
        uint256 amount;
        address destination;
    }

    struct PermitParams {
        ExchangeParams exchange;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // ======================================================
    // External Functions
    // ======================================================
    function initialize(InitParams calldata params) external;

    function setDefaultToken(address _newDefaultToken) external;
    function addPaymentToken(address token, address priceFeed) external;
    function removePaymentToken(address token) external;
    function getSupportedTokens() external view returns (address[] memory);

    function exchange(ExchangeParams calldata params) external;

    function exchangeWithPermit(PermitParams calldata params) external;

    function setVaultFactory(address _vaultFactory) external;
    function setVaultGasStation(address vault, address gasStation) external;
    function emergencyWithdrawToken(WithdrawalParams calldata params) external;
    function enableEmergencyMode() external;
    function disableEmergencyMode() external;

    function calculateEthAmount(address token, uint256 amount) external view returns (uint256);
    function findBestVault(
        uint256 requiredEth
    ) external view returns (address vault, uint256 balance);
}
