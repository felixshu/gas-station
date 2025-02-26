// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IVault } from "./interfaces/IVault.sol";
import { ITokenWhitelist } from "./interfaces/ITokenWhitelist.sol";
import { Errors } from "./libraries/Errors.sol";

/**
 * @title Vault
 * @dev Contract for managing user funds
 * Optimized for gas efficiency with calldata and storage optimizations
 */
contract Vault is
    IVault,
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ======================================================
    // State Variables
    // ======================================================

    // @dev Token whitelist contract address
    address public tokenWhitelist;

    // @dev Gas station contract address
    address public gasStation;

    // @dev User balances mapping: user => token => amount
    mapping(address => mapping(address => uint256)) private _balances;

    // @dev Total deposits per token
    mapping(address => uint256) private _totalDeposits;

    // ======================================================
    // Modifiers
    // ======================================================

    /**
     * @dev Modifier to restrict access to gas station only
     */
    modifier onlyGasStation() {
        if (msg.sender != gasStation) revert Errors.NotGasStation(msg.sender, gasStation);
        _;
    }

    /**
     * @dev Modifier to check if token is whitelisted
     * @param token The token address to check
     */
    modifier onlyWhitelistedToken(address token) {
        if (token != address(0) && !ITokenWhitelist(tokenWhitelist).isTokenWhitelisted(token))
            revert Errors.TokenNotWhitelisted(token);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     * @param params The initialization parameters
     */
    function initialize(InitParams calldata params) external initializer {
        __Ownable_init(params.owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (params.whitelist == address(0)) revert Errors.InvalidAddress(params.whitelist);
        tokenWhitelist = params.whitelist;
        gasStation = params.owner; // Set gasStation to owner initially
    }

    /**
     * @dev Set the token whitelist contract
     * @param _whitelist The token whitelist contract
     */
    function setTokenWhitelist(address _whitelist) external onlyOwner {
        if (_whitelist == address(0)) revert Errors.InvalidAddress(_whitelist);
        tokenWhitelist = _whitelist;
        emit WhitelistSet(_whitelist);
    }

    /**
     * @dev Set the gas station contract
     * @param _gasStation The gas station contract
     */
    function setGasStation(address _gasStation) external onlyOwner {
        if (_gasStation == address(0)) revert Errors.InvalidAddress(_gasStation);
        gasStation = _gasStation;
    }

    /**
     * @dev Deposit ETH into the vault
     */
    function depositEth() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert Errors.ZeroAmount();

        // Update balances in a single storage operation
        address sender = msg.sender;
        uint256 value = msg.value;

        // Cache the current balance to avoid multiple storage reads
        uint256 currentBalance = _balances[sender][address(0)];
        uint256 newBalance = currentBalance + value;

        // Update user balance
        _balances[sender][address(0)] = newBalance;

        // Update total deposits
        _totalDeposits[address(0)] += value;

        emit Deposited(sender, address(0), value);
    }

    /**
     * @dev Deposit tokens into the vault
     * @param params The token parameters
     */
    function depositToken(
        TokenParams calldata params
    ) external nonReentrant whenNotPaused onlyWhitelistedToken(params.token) {
        if (params.amount == 0) revert Errors.ZeroAmount();

        address sender = msg.sender;
        address token = params.token;
        uint256 amount = params.amount;

        // Transfer tokens from sender to vault
        IERC20(token).safeTransferFrom(sender, address(this), amount);

        // Cache the current balance to avoid multiple storage reads
        uint256 currentBalance = _balances[sender][token];
        uint256 newBalance = currentBalance + amount;

        // Update user balance
        _balances[sender][token] = newBalance;

        // Update total deposits
        _totalDeposits[token] += amount;

        emit Deposited(sender, token, amount);
    }

    /**
     * @dev Withdraw ETH from the vault
     * @param params The ETH parameters
     */
    function withdrawEth(EthParams calldata params) external onlyOwner nonReentrant whenNotPaused {
        if (params.amount == 0) revert Errors.ZeroAmount();

        address sender = msg.sender;
        uint256 amount = params.amount;
        address recipient = params.recipient;

        // Cache the current balance to avoid multiple storage reads
        uint256 currentBalance = _balances[sender][address(0)];

        if (currentBalance < amount)
            revert Errors.InsufficientBalance(sender, currentBalance, amount);

        // Update balances
        _balances[sender][address(0)] = currentBalance - amount;
        _totalDeposits[address(0)] -= amount;

        // Transfer ETH
        (bool success, ) = recipient.call{ value: amount }("");
        if (!success) revert Errors.TransferFailed(address(0), address(this), recipient, amount);

        emit Withdrawn(sender, address(0), amount);
    }

    /**
     * @dev Withdraw tokens from the vault
     * @param params The token parameters
     */
    function withdrawToken(
        TokenParams calldata params
    ) external onlyOwner nonReentrant whenNotPaused onlyWhitelistedToken(params.token) {
        if (params.amount == 0) revert Errors.ZeroAmount();

        address sender = msg.sender;
        address token = params.token;
        uint256 amount = params.amount;
        address recipient = params.recipient;

        // Cache the current balance to avoid multiple storage reads
        uint256 currentBalance = _balances[sender][token];

        if (currentBalance < amount)
            revert Errors.InsufficientBalance(sender, currentBalance, amount);

        // Update balances
        _balances[sender][token] = currentBalance - amount;
        _totalDeposits[token] -= amount;

        // Transfer tokens
        IERC20(token).safeTransfer(recipient, amount);

        emit Withdrawn(sender, token, amount);
    }

    /**
     * @dev Send ETH to a destination
     * @param params The ETH parameters
     */
    function sendEth(EthParams calldata params) external onlyGasStation nonReentrant {
        uint256 balance = address(this).balance;
        if (balance < params.amount)
            revert Errors.InsufficientBalance(address(this), balance, params.amount);

        // Use Address.sendValue instead of low-level call
        Address.sendValue(payable(params.recipient), params.amount);

        emit EthSent(params.recipient, params.amount);
    }

    /**
     * @dev Pause the contract in case of emergency
     */
    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyPaused();
    }

    /**
     * @dev Unpause the contract
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused();
    }

    /**
     * @dev Recover tokens in case of emergency
     * @param params The token parameters
     */
    function emergencyRecoverToken(TokenParams calldata params) external onlyOwner nonReentrant {
        if (!paused()) revert Errors.ExpectedPause();
        IERC20(params.token).safeTransfer(params.recipient, params.amount);
        emit EmergencyRecovery(params.token, params.amount, params.recipient);
    }

    /**
     * @dev Recover ETH in case of emergency
     * @param params The ETH parameters
     */
    function emergencyRecoverEth(EthParams calldata params) external onlyOwner nonReentrant {
        if (!paused()) revert Errors.ExpectedPause();

        // Use Address.sendValue instead of low-level call
        Address.sendValue(payable(params.recipient), params.amount);

        emit EmergencyRecovery(address(0), params.amount, params.recipient);
    }

    /**
     * @dev Get the balance of a user for a specific token
     * @param user The user address
     * @param token The token address
     * @return The balance of the user for the token
     */
    function balances(address user, address token) external view returns (uint256) {
        return _balances[user][token];
    }

    /**
     * @dev Get the total deposits for a specific token
     * @param token The token address
     * @return The total deposits for the token
     */
    function totalDeposits(address token) external view returns (uint256) {
        return _totalDeposits[token];
    }

    /**
     * @dev Receive ETH
     */
    receive() external payable {
        emit Deposited(msg.sender, address(0), msg.value);
    }

    /**
     * @dev Function to authorize an upgrade to a new implementation
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
