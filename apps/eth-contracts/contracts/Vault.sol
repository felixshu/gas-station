// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVault } from "./interfaces/IVault.sol";
import { ITokenWhitelist } from "./interfaces/ITokenWhitelist.sol";
import { Errors } from "./libraries/Errors.sol";

/**
 * @title Vault
 * @dev Contract for managing user funds
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

    // State variables
    address public tokenWhitelist;
    address public gasStation;

    // User balances mapping: user => token => amount
    mapping(address => mapping(address => uint256)) private _balances;

    // Total deposits per token
    mapping(address => uint256) private _totalDeposits;

    // Modifiers
    modifier onlyGasStation() {
        if (msg.sender != gasStation) revert Errors.NotGasStation();
        _;
    }

    modifier onlyWhitelistedToken(address token) {
        if (token != address(0) && !ITokenWhitelist(tokenWhitelist).isTokenWhitelisted(token))
            revert Errors.TokenNotWhitelisted();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     * @param owner_ The owner of the contract
     * @param whitelist_ The token whitelist contract
     */
    function initialize(address owner_, address whitelist_) external initializer {
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (whitelist_ == address(0)) revert Errors.InvalidAddress();
        tokenWhitelist = whitelist_;
        gasStation = owner_; // Set gasStation to owner initially
    }

    /**
     * @dev Set the token whitelist contract
     * @param _whitelist The token whitelist contract
     */
    function setTokenWhitelist(address _whitelist) external onlyOwner {
        if (_whitelist == address(0)) revert Errors.InvalidAddress();
        tokenWhitelist = _whitelist;
        emit WhitelistSet(_whitelist);
    }

    /**
     * @dev Set the gas station contract
     * @param _gasStation The gas station contract
     */
    function setGasStation(address _gasStation) external onlyOwner {
        if (_gasStation == address(0)) revert Errors.InvalidAddress();
        gasStation = _gasStation;
    }

    /**
     * @dev Deposit ETH into the vault
     */
    function depositEth() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert Errors.ZeroAmount();

        // Update balances
        _balances[msg.sender][address(0)] += msg.value;
        _totalDeposits[address(0)] += msg.value;

        emit Deposited(msg.sender, address(0), msg.value);
    }

    /**
     * @dev Deposit tokens into the vault
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function depositToken(
        address token,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyWhitelistedToken(token) {
        if (amount == 0) revert Errors.ZeroAmount();

        // Transfer tokens from sender to vault
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update balances
        _balances[msg.sender][token] += amount;
        _totalDeposits[token] += amount;

        emit Deposited(msg.sender, token, amount);
    }

    /**
     * @dev Withdraw ETH from the vault
     * @param amount The amount to withdraw
     * @param to The address to withdraw to
     */
    function withdrawEth(uint256 amount, address to) external onlyOwner nonReentrant whenNotPaused {
        if (amount == 0) revert Errors.ZeroAmount();
        if (_balances[msg.sender][address(0)] < amount) revert Errors.InsufficientBalance();

        // Update balances
        _balances[msg.sender][address(0)] -= amount;
        _totalDeposits[address(0)] -= amount;

        // Transfer ETH
        (bool success, ) = to.call{ value: amount }("");
        if (!success) revert Errors.TransferFailed();

        emit Withdrawn(msg.sender, address(0), amount);
    }

    /**
     * @dev Withdraw tokens from the vault
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     * @param to The address to withdraw to
     */
    function withdrawToken(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner nonReentrant whenNotPaused onlyWhitelistedToken(token) {
        if (amount == 0) revert Errors.ZeroAmount();
        if (_balances[msg.sender][token] < amount) revert Errors.InsufficientBalance();

        // Update balances
        _balances[msg.sender][token] -= amount;
        _totalDeposits[token] -= amount;

        // Transfer tokens
        IERC20(token).safeTransfer(to, amount);

        emit Withdrawn(msg.sender, token, amount);
    }

    /**
     * @dev Send ETH to a destination
     * @param destination The destination to send ETH to
     * @param amount The amount to send
     */
    function sendEth(address destination, uint256 amount) external onlyGasStation nonReentrant {
        if (address(this).balance < amount) revert Errors.InsufficientBalance();

        // Perform the ETH transfer
        (bool success, ) = destination.call{ value: amount }("");
        if (!success) revert Errors.TransferFailed();

        emit EthSent(destination, amount);
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
     * @param token The token to recover
     * @param amount The amount to recover
     * @param to The address to recover to
     */
    function emergencyRecoverToken(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner nonReentrant {
        if (!paused()) revert Errors.ExpectedPause();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyRecovery(token, amount, to);
    }

    /**
     * @dev Recover ETH in case of emergency
     * @param amount The amount to recover
     * @param to The address to recover to
     */
    function emergencyRecoverEth(uint256 amount, address to) external onlyOwner nonReentrant {
        if (!paused()) revert Errors.ExpectedPause();
        (bool success, ) = to.call{ value: amount }("");
        if (!success) revert Errors.TransferFailed();
        emit EmergencyRecovery(address(0), amount, to);
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
