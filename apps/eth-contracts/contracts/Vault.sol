// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenWhitelist} from "./TokenWhitelist.sol";
import {Errors} from "./libraries/Errors.sol";
import {IVault} from "./interfaces/IVault.sol";

contract Vault is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IVault
{
    using SafeERC20 for IERC20;

    // Token whitelist instance
    TokenWhitelist public tokenWhitelist;
    // Gas station instance
    address public gasStation;

    // @dev Mapping of user => (token => balance). For ETH, use address(0).
    mapping(address => mapping(address => uint256)) public balances;
    // @dev Tracks total user deposits per token (including ETH at address(0)).
    mapping(address => uint256) public totalDeposits;

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
     * @dev Sets the token whitelist contract
     * @param _whitelist Address of the TokenWhitelist contract
     */
    function setTokenWhitelist(address _whitelist) external onlyOwner {
        if (_whitelist == address(0)) revert Errors.InvalidAddress();
        tokenWhitelist = TokenWhitelist(_whitelist);
        emit WhitelistSet(_whitelist);
    }

    /**
     * @dev Set the gas station address
     * @param _gasStation Address of the gas station
     */
    function setGasStation(address _gasStation) external onlyOwner {
        if (_gasStation == address(0)) revert Errors.InvalidAddress();
        gasStation = _gasStation;
    }

    /**
     * @dev Checks if a token is whitelisted
     * @param token Address of the token to check
     */
    function _isTokenWhitelisted(address token) internal view returns (bool) {
        if (address(tokenWhitelist) == address(0)) revert Errors.TokenNotWhitelisted();
        return token == address(0) || tokenWhitelist.isTokenWhitelisted(token);
    }

    /**
     * @dev Deposit ETH into the vault.
     * Updates the sender's balance and the total deposits.
     * Only allowed when the contract is not paused.
     */
    function depositEth() external payable whenNotPaused {
        balances[msg.sender][address(0)] += msg.value;
        totalDeposits[address(0)] += msg.value;
    }

    /**
     * @dev Deposit ERC20 tokens into the vault.
     * Updates the sender's token balance and total deposits.
     * Only allowed when the contract is not paused.
     * Uses custom error if amount is zero.
     * @param token The ERC20 token address.
     * @param amount The token amount to deposit (must be > 0).
     */
    function depositToken(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Errors.ZeroAmount();
        if (!_isTokenWhitelisted(token)) revert Errors.TokenNotWhitelisted();
        balances[msg.sender][token] += amount;
        totalDeposits[token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, token, amount);
    }

    /**
     * @dev Withdraw ETH from the vault.
     * Decreases the sender's balance and the total deposits.
     * If the transfer fails, reverts with a custom error.
     * @param amount The amount of ETH to withdraw.
     * @param to The address to receive the ETH. If zero address, sends to msg.sender.
     */
    function withdrawEth(uint256 amount, address to) external nonReentrant whenNotPaused onlyOwner {
        address recipient = to == address(0) ? msg.sender : to;
        // Only owner can withdraw to a different address
        if (to != address(0) && to != msg.sender && msg.sender != owner()) revert Errors.InvalidAddress();
        if (balances[msg.sender][address(0)] < amount) revert Errors.InsufficientBalance();
        balances[msg.sender][address(0)] -= amount;
        totalDeposits[address(0)] -= amount;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert Errors.EthTransferFailed();
        emit Withdrawn(msg.sender, address(0), amount);
    }

    /**
     * @dev Withdraw ERC20 tokens from the vault.
     * Decreases the sender's token balance and the total deposits.
     * @param token The ERC20 token address.
     * @param amount The token amount to withdraw.
     * @param to The address to receive the tokens. If zero address, sends to msg.sender.
     */
    function withdrawToken(address token, uint256 amount, address to) external nonReentrant whenNotPaused onlyOwner {
        address recipient = to == address(0) ? msg.sender : to;
        // Only owner can withdraw to a different address
        if (to != address(0) && to != msg.sender && msg.sender != owner()) revert Errors.InvalidAddress();
        if (balances[msg.sender][token] < amount) revert Errors.InsufficientBalance();
        if (!_isTokenWhitelisted(token)) revert Errors.TokenNotWhitelisted();
        balances[msg.sender][token] -= amount;
        totalDeposits[token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    /**
     * @dev Internal function to handle ETH deposits
     */
    function _handleEthDeposit() internal {
        balances[msg.sender][address(0)] += msg.value;
        totalDeposits[address(0)] += msg.value;
        emit Deposited(msg.sender, address(0), msg.value);
    }

    /**
     * @dev Fallback function to accept ETH transfers.
     */
    receive() external payable whenNotPaused {
        _handleEthDeposit();
    }

    /**
     * @dev Send ETH to a destination (only callable by GasStation)
     * @param destination Address to receive ETH
     * @param amount Amount of ETH to send
     */
    function sendEth(address destination, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != address(gasStation)) revert Errors.UnauthorizedAccess();
        if (address(this).balance < amount) revert Errors.InsufficientBalance();

        (bool success,) = destination.call{value: amount}("");
        if (!success) revert Errors.EthTransferFailed();
    }

    // ==============================================================
    //                   Emergency Functions
    // ==============================================================

    /**
     * @dev Pause deposit functions in case of emergency.
     * When paused, new deposits are disabled but withdrawals remain available.
     * Only the owner can trigger this.
     */
    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyPaused();
    }

    /**
     * @dev Unpause deposit functions after an emergency.
     * Only the owner can trigger this.
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused();
    }

    /**
     * @dev Emergency recovery of excess ERC20 tokens not allocated to user deposits.
     * This function can only be called when the contract is paused.
     * It calculates the recoverable (excess) amount as the difference between the token balance
     * held by the contract and the total user deposits tracked.
     * @param token The ERC20 token address to recover.
     * @param amount The amount to recover.
     * @param to The address that will receive the recovered tokens.
     */
    function emergencyRecoverToken(address token, uint256 amount, address to)
        external
        nonReentrant
        whenPaused
        onlyOwner
    {
        if (!paused()) revert Errors.NotInEmergencyMode();
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        uint256 allocated = totalDeposits[token];
        if (amount > contractBalance - allocated) revert Errors.InsufficientBalance();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyRecovery(token, amount, to);
    }

    /**
     * @dev Emergency recovery of excess ETH not allocated to user deposits.
     * This function can only be called when the contract is paused.
     * It calculates the recoverable ETH as the difference between the contract's ETH balance
     * and the total ETH deposits tracked.
     * @param amount The amount of ETH to recover.
     * @param to The address that will receive the recovered ETH.
     */
    function emergencyRecoverEth(uint256 amount, address to) external nonReentrant whenPaused onlyOwner {
        if (!paused()) revert Errors.NotInEmergencyMode();
        uint256 contractBalance = address(this).balance;
        uint256 allocated = totalDeposits[address(0)];
        if (amount > contractBalance - allocated) revert Errors.InsufficientBalance();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert Errors.EthTransferFailed();
        emit EmergencyRecovery(address(0), amount, to);
    }

    //==============================================================
    //                   UUPS Upgradeable Functions
    //==============================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
