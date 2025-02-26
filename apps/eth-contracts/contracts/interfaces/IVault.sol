// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVault
 * @dev Interface for the Vault contract
 */
interface IVault {
    // ======================================================
    // Structs
    // ======================================================

    /**
     * @dev Struct for initialization parameters to reduce calldata size
     */
    struct InitParams {
        address owner;
        address whitelist;
    }

    /**
     * @dev Struct for token operations to reduce calldata size
     */
    struct TokenParams {
        address token;
        uint256 amount;
        address recipient;
    }

    /**
     * @dev Struct for ETH operations to reduce calldata size
     */
    struct EthParams {
        uint256 amount;
        address recipient;
    }

    // ======================================================
    // Events
    // ======================================================

    // @dev Event emitted when whitelist is set
    event WhitelistSet(address indexed whitelist);

    // @dev Event emitted when a deposit is made
    event Deposited(address indexed user, address indexed token, uint256 amount);

    // @dev Event emitted when a withdrawal is made
    event Withdrawn(address indexed user, address indexed token, uint256 amount);

    // @dev Event emitted when emergency mode is activated
    event EmergencyPaused();

    // @dev Event emitted when emergency mode is deactivated
    event EmergencyUnpaused();

    // @dev Event emitted when an emergency recovery is made
    event EmergencyRecovery(address indexed token, uint256 amount, address indexed to);

    // @dev Event emitted when ETH is sent
    event EthSent(address indexed destination, uint256 amount);

    // ======================================================
    // Functions
    // ======================================================

    /**
     * @dev Initialize the contract
     * @param params The initialization parameters
     */
    function initialize(InitParams calldata params) external;

    /**
     * @dev Set the token whitelist contract
     * @param _whitelist The token whitelist contract
     */
    function setTokenWhitelist(address _whitelist) external;

    /**
     * @dev Set the gas station contract
     * @param _gasStation The gas station contract
     */
    function setGasStation(address _gasStation) external;

    /**
     * @dev Deposit ETH into the vault
     */
    function depositEth() external payable;

    /**
     * @dev Deposit tokens into the vault
     * @param params The token parameters
     */
    function depositToken(TokenParams calldata params) external;

    /**
     * @dev Withdraw ETH from the vault
     * @param params The ETH parameters
     */
    function withdrawEth(EthParams calldata params) external;

    /**
     * @dev Withdraw tokens from the vault
     * @param params The token parameters
     */
    function withdrawToken(TokenParams calldata params) external;

    /**
     * @dev Send ETH to a destination
     * @param params The ETH parameters
     */
    function sendEth(EthParams calldata params) external;

    /**
     * @dev Pause the contract in case of emergency
     */
    function emergencyPause() external;

    /**
     * @dev Unpause the contract
     */
    function emergencyUnpause() external;

    /**
     * @dev Recover tokens in case of emergency
     * @param params The token parameters
     */
    function emergencyRecoverToken(TokenParams calldata params) external;

    /**
     * @dev Recover ETH in case of emergency
     * @param params The ETH parameters
     */
    function emergencyRecoverEth(EthParams calldata params) external;
}
