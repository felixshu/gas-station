// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Errors} from "./libraries/Errors.sol";
import {IGasStation} from "./interfaces/IGasStation.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Vault} from "./Vault.sol";
import {PaymentTokenConfig} from "./types/PaymentTypes.sol";

/**
 * @title GasStation
 * @dev Handles token deposits and distributes ETH for gas fees.
 */
contract GasStation is
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IGasStation
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ======================================================
    // State Variables
    // ======================================================
    // @dev USDC token contract
    IERC20 public usdcToken;
    // @dev ETH/USD price feed
    AggregatorV3Interface public ethUsdPriceFeed;
    // @dev Vault factory contract
    VaultFactory public vaultFactory;
    // @dev Maximum number of vaults
    uint256 public constant MAX_VAULTS = 10; // Limit number of vaults for gas efficiency
    // @dev Minimum deposit amount (in token decimals)
    uint256 public minDepositAmount;
    // @dev Maximum deposit amount (in token decimals)
    uint256 public maxDepositAmount;
    // @dev Maximum deposits per block
    uint256 public constant MAX_DEPOSITS_PER_BLOCK = 10;
    // @dev Deposits per block
    mapping(uint256 => uint256) public depositsPerBlock;

    // @dev Mapping of payment token address to its configuration
    mapping(address => PaymentTokenConfig) public paymentTokens;

    // @dev List of supported payment tokens for iteration
    EnumerableSet.AddressSet private supportedTokens;

    // @dev Default payment token address (e.g. USDC)
    address public defaultToken;

    // @dev Price feed decimals
    uint256 public constant PRICE_FEED_DECIMALS = 8;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract.
     * @param _defaultToken Default payment token address (e.g. USDC)
     * @param _defaultPriceFeed Default price feed address (token/ETH)
     * @param _minDepositAmount Minimum deposit amount (in token decimals)
     * @param _maxDepositAmount Maximum deposit amount (in token decimals)
     * @param _vaultFactory Vault factory contract address
     */
    function initialize(
        address _defaultToken,
        address _defaultPriceFeed,
        uint256 _minDepositAmount,
        uint256 _maxDepositAmount,
        address _vaultFactory
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();

        if (_defaultToken == address(0)) revert Errors.InvalidAddress();
        if (_defaultPriceFeed == address(0)) revert Errors.InvalidAddress();
        if (_vaultFactory == address(0)) revert Errors.InvalidAddress();

        vaultFactory = VaultFactory(_vaultFactory);
        minDepositAmount = _minDepositAmount;
        maxDepositAmount = _maxDepositAmount;

        defaultToken = _defaultToken;
        _addPaymentToken(_defaultToken, _defaultPriceFeed);

        emit DefaultTokenUpdated(_defaultToken);
    }

    /**
     * @dev Set a new default token from existing supported tokens
     * @param _newDefaultToken New default token address
     */
    function setDefaultToken(address _newDefaultToken) external onlyOwner {
        if (!paymentTokens[_newDefaultToken].isSupported) revert Errors.TokenNotSupported();
        defaultToken = _newDefaultToken;
        emit DefaultTokenUpdated(_newDefaultToken);
    }

    /**
     * @dev Add or update a payment token
     * @param token Token address
     * @param priceFeed Price feed address for token/ETH
     */
    function addPaymentToken(address token, address priceFeed) external onlyOwner {
        _addPaymentToken(token, priceFeed);
    }

    /**
     * @dev Internal function to add or update a payment token
     */
    function _addPaymentToken(address token, address priceFeed) internal {
        if (token == address(0) || priceFeed == address(0)) revert Errors.InvalidAddress();

        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        if (!paymentTokens[token].isSupported) {
            supportedTokens.add(token);
        }

        paymentTokens[token] = PaymentTokenConfig({
            isSupported: true,
            decimals: tokenDecimals,
            priceFeed: AggregatorV3Interface(priceFeed)
        });

        emit PaymentTokenUpdated(token, tokenDecimals, priceFeed);
    }

    /**
     * @dev Remove a payment token
     * @param token Token address to remove
     */
    function removePaymentToken(address token) external onlyOwner {
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported();

        delete paymentTokens[token];
        supportedTokens.remove(token);

        emit PaymentTokenRemoved(token);
    }

    /**
     * @dev Get all supported payment tokens
     * @return Array of supported token addresses
     */
    function getSupportedTokens() external view returns (address[] memory) {
        uint256 length = supportedTokens.length();
        address[] memory tokens = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            tokens[i] = supportedTokens.at(i);
        }
        return tokens;
    }

    /**
     * @dev Calculate ETH amount based on input token amount using appropriate Chainlink price feed.
     * @param token Input token address
     * @param amount Amount of input token
     * @return ethAmount Amount of ETH
     */
    function calculateEthAmount(address token, uint256 amount) public view returns (uint256) {
        if (amount == 0) revert Errors.ZeroAmount();
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported();

        PaymentTokenConfig memory config = paymentTokens[token];
        (uint80 roundId, int256 price,, uint256 updatedAt,) = config.priceFeed.latestRoundData();

        if (roundId < 1) revert Errors.InvalidEthRoundId();
        if (price <= 0) revert Errors.InvalidEthPrice();
        if (block.timestamp - updatedAt > 30 minutes) revert Errors.StalePrice();
        if (uint256(price) >= type(uint256).max / 1e20) revert Errors.PriceOverflow();

        uint256 scalingFactor = 10 ** (20 - config.decimals);

        unchecked {
            return (amount * scalingFactor) / uint256(price);
        }
    }

    /**
     * @dev Deposit tokens to the vault and send ETH to the user's wallet.
     * If no token is specified (address(0)), uses the default token.
     */
    function exchangeWithPermit(
        address token,
        uint256 amount,
        address destination,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        // Use default token if none specified
        address tokenToUse = token == address(0) ? defaultToken : token;
        if (!paymentTokens[tokenToUse].isSupported) revert Errors.TokenNotSupported();

        // Validate inputs
        if (deadline < block.timestamp) revert Errors.ExpiredDeadline();
        if (destination == address(this)) revert Errors.InvalidDestination();
        if (amount < minDepositAmount) revert Errors.AmountBelowMinimum();
        if (amount > maxDepositAmount) revert Errors.AmountAboveMaximum();
        if (depositsPerBlock[block.number] >= MAX_DEPOSITS_PER_BLOCK) revert Errors.RateLimitExceeded();

        uint256 ethAmount = calculateEthAmount(tokenToUse, amount);
        address effectiveDestination = destination == address(0) ? msg.sender : destination;

        // Find vault with sufficient ETH balance
        (address vault,) = findBestVault(ethAmount);

        // State changes
        depositsPerBlock[block.number]++;

        // External calls after all state changes
        IERC20Permit(tokenToUse).permit(msg.sender, address(this), amount, deadline, v, r, s);

        // Transfer and deposit
        IERC20(tokenToUse).safeTransferFrom(msg.sender, address(this), amount);
        SafeERC20.forceApprove(IERC20(tokenToUse), vault, amount);
        Vault(payable(vault)).depositToken(tokenToUse, amount);
        Vault(payable(vault)).sendEth(effectiveDestination, ethAmount);

        emit DepositProcessed(msg.sender, effectiveDestination, tokenToUse, amount, ethAmount);
    }

    /**
     * @dev Reject direct ETH transfers.
     */
    receive() external payable {
        revert Errors.DirectDepositNotAllowed();
    }

    /**
     * @dev Reject direct ETH transfers with data.
     */
    fallback() external payable {
        revert Errors.DirectDepositNotAllowed();
    }

    /**
     * @dev Find the vault with sufficient ETH balance.
     * Prioritizes vaults with sufficient balance and optimizes for gas usage.
     * @param requiredEth The minimum ETH balance required.
     * @return vault Address of the selected vault.
     * @return balance The ETH balance of the selected vault.
     */
    function findBestVault(uint256 requiredEth) public view returns (address vault, uint256 balance) {
        uint256 vaultCount = vaultFactory.getVaultCountByOwner(address(this));
        if (vaultCount == 0) revert Errors.VaultNotFound();

        uint256 totalBalance = 0;
        address bestVault = address(0);
        uint256 bestBalance = 0;

        // First check the most recently created vault
        address lastVault = vaultFactory.getLastVaultByOwner(address(this));
        if (lastVault != address(0)) {
            uint256 lastVaultBalance = address(payable(lastVault)).balance;
            totalBalance = lastVaultBalance;

            // If the last vault has enough balance, use it
            if (lastVaultBalance >= requiredEth) {
                return (lastVault, lastVaultBalance);
            }

            // Keep track of it as potential best vault
            if (lastVaultBalance > bestBalance) {
                bestVault = lastVault;
                bestBalance = lastVaultBalance;
            }
        }

        // Check other vaults if needed
        for (uint256 i = 0; i < vaultCount; i++) {
            address currentVault = vaultFactory.getVaultByOwnerAndIndex(address(this), i);
            if (currentVault == lastVault) continue; // Skip last vault as we already checked it

            uint256 vaultBalance = address(payable(currentVault)).balance;
            totalBalance += vaultBalance;

            // If we find a vault with sufficient balance, return it immediately
            if (vaultBalance >= requiredEth) {
                return (currentVault, vaultBalance);
            }

            // Keep track of the vault with highest balance
            if (vaultBalance > bestBalance) {
                bestVault = currentVault;
                bestBalance = vaultBalance;
            }
        }

        // If no vault has sufficient balance
        if (totalBalance < requiredEth) {
            revert Errors.InsufficientBalance();
        }

        // If total balance is sufficient but no single vault has enough
        revert Errors.VaultBalanceDistributionNeeded();
    }

    /**
     * @dev Set the vault factory address.
     * @param _vaultFactory New vault factory address.
     */
    function setVaultFactory(address _vaultFactory) external nonReentrant onlyOwner {
        if (_vaultFactory == address(0)) revert Errors.InvalidAddress();
        vaultFactory = VaultFactory(_vaultFactory);
        // check if any vaults exist for this contract
        uint256 vaultCount = vaultFactory.getVaultCountByOwner(address(this));
        if (vaultCount == 0) {
            vaultFactory.createVault();
        }
        emit VaultFactorySet(_vaultFactory);
    }

    // ======================================================
    // Emergency Withdrawals
    // ======================================================

    /**
     * @dev Emergency withdraw any ERC20 token.
     * Can only be called when the contract is paused.
     * @param token Address of token to withdraw.
     * @param amount Amount of token to withdraw.
     * @param to Address to send tokens to.
     */
    function emergencyWithdrawToken(address token, uint256 amount, address to) external nonReentrant onlyOwner {
        if (!paused()) revert Errors.NotInEmergencyMode();
        if (token == address(0) || to == address(0)) revert Errors.InvalidAddress();
        IERC20 tokenContract = IERC20(token);
        if (amount > tokenContract.balanceOf(address(this))) revert Errors.InsufficientBalance();
        tokenContract.safeTransfer(to, amount);
        emit EmergencyWithdrawal(token, amount, to);
    }

    /**
     * @dev Enable emergency mode (pauses contract).
     */
    function enableEmergencyMode() external onlyOwner {
        _pause();
        emit EmergencyModeEnabled();
    }

    /**
     * @dev Disable emergency mode (unpauses contract).
     */
    function disableEmergencyMode() external onlyOwner {
        _unpause();
        emit EmergencyModeDisabled();
    }

    //==============================================================
    //                   UUPS Upgradeable Functions
    //==============================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Internal function to check if a new vault is needed based on current conditions
     * @param vaults Array of current vault addresses
     * @param totalBalance Total ETH balance across all vaults
     * @return bool True if a new vault should be created
     */
    function _shouldCreateNewVault(address[] memory vaults, uint256 totalBalance) internal view returns (bool) {
        // Don't create new vault if we've reached the limit
        if (vaults.length >= MAX_VAULTS) return false;

        // Create new vault if:
        // 1. Average balance per vault is above a certain threshold (e.g., 100 ETH)
        // 2. Total number of transactions in recent blocks is high
        uint256 averageBalance = totalBalance / vaults.length;
        return averageBalance >= 100 ether || depositsPerBlock[block.number] >= MAX_DEPOSITS_PER_BLOCK - 1;
    }
}
