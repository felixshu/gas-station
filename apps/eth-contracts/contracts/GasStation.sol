// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { Errors } from "./libraries/Errors.sol";
import { IGasStation } from "./interfaces/IGasStation.sol";
import { VaultFactory } from "./VaultFactory.sol";
import { Vault } from "./Vault.sol";
import { PaymentTokenConfig } from "./types/PaymentTypes.sol";

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
    // @dev Last processed block number
    uint256 private _lastProcessedBlock;

    // @dev Mapping of payment token address to its configuration
    mapping(address => PaymentTokenConfig) public paymentTokens;

    // @dev List of supported payment tokens for iteration
    EnumerableSet.AddressSet private _supportedTokens;

    // @dev Default payment token address (e.g. USDC)
    address public defaultToken;

    // @dev Price feed decimals
    uint256 public constant PRICE_FEED_DECIMALS = 8;

    // Add these events near the top with other events
    event RateLimitCheck(uint256 currentBlock, uint256 lastProcessedBlock, uint256 currentDeposits);
    event RateLimitUpdated(uint256 blockNumber, uint256 newCount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract.
     */
    function initialize(
        address _defaultToken,
        address _defaultPriceFeed,
        uint256 _minDepositAmount,
        uint256 _maxDepositAmount,
        address _vaultFactory
    ) public initializer {
        __ReentrancyGuard_init();
        __Ownable_init(msg.sender);
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
     * @dev Set a new default token from existing supported tokens
     */
    function setDefaultToken(address _newDefaultToken) external onlyOwner {
        if (!paymentTokens[_newDefaultToken].isSupported) revert Errors.TokenNotSupported();
        defaultToken = _newDefaultToken;
        emit DefaultTokenUpdated(_newDefaultToken);
    }

    /**
     * @dev Add or update a payment token
     */
    function addPaymentToken(address token, address priceFeed) external onlyOwner {
        _addPaymentToken(token, priceFeed);
    }

    /**
     * @dev Remove a payment token
     */
    function removePaymentToken(address token) external onlyOwner {
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported();

        delete paymentTokens[token];
        _supportedTokens.remove(token);

        emit PaymentTokenRemoved(token);
    }

    /**
     * @dev Exchange tokens for ETH using regular approve/transferFrom pattern.
     * @param token Input token address (use address(0) for default token)
     * @param amount Amount of tokens to exchange
     * @param destination Address to receive ETH (use address(0) for msg.sender)
     */
    function exchange(
        address token,
        uint256 amount,
        address destination
    ) external nonReentrant whenNotPaused {
        _executeExchange(token, amount, destination);
    }

    /**
     * @dev Exchange tokens for ETH using permit for approval.
     * @param token Input token address (use address(0) for default token)
     * @param amount Amount of tokens to exchange
     * @param destination Address to receive ETH (use address(0) for msg.sender)
     * @param deadline Deadline for the permit signature
     * @param v ECDSA signature v
     * @param r ECDSA signature r
     * @param s ECDSA signature s
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

        // Validate deadline
        if (deadline < block.timestamp) revert Errors.ExpiredDeadline();

        // Execute permit
        IERC20Permit(tokenToUse).permit(msg.sender, address(this), amount, deadline, v, r, s);

        // Execute the exchange
        _executeExchange(token, amount, destination);
    }

    /**
     * @dev Set the vault factory address.
     */
    function setVaultFactory(address _vaultFactory) external nonReentrant onlyOwner {
        if (_vaultFactory == address(0)) revert Errors.InvalidAddress();
        vaultFactory = VaultFactory(_vaultFactory);
        emit VaultFactorySet(_vaultFactory);
    }

    /**
     * @dev Set the gas station address in a Vault contract.
     * @param vault The vault address
     * @param gasStation The gas station address
     */
    function setVaultGasStation(address vault, address gasStation) external nonReentrant onlyOwner {
        if (vault == address(0) || gasStation == address(0)) revert Errors.InvalidAddress();
        Vault(payable(vault)).setGasStation(gasStation);
    }

    /**
     * @dev Emergency withdraw any ERC20 token.
     */
    function emergencyWithdrawToken(
        address token,
        uint256 amount,
        address to
    ) external nonReentrant onlyOwner {
        if (!paused()) revert Errors.NotInEmergencyMode();
        if (token == address(0) || to == address(0)) revert Errors.InvalidAddress();
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        if (amount > balance) revert Errors.InsufficientBalance();
        tokenContract.safeTransfer(to, amount);
        emit EmergencyWithdrawal(token, amount, to);
    }

    /**
     * @dev Enable emergency mode (pauses contract).
     */
    function enableEmergencyMode() external onlyOwner {
        if (paused()) revert Errors.ContractPaused();
        _pause();
        emit EmergencyModeEnabled();
    }

    /**
     * @dev Disable emergency mode (unpauses contract).
     */
    function disableEmergencyMode() external onlyOwner {
        if (!paused()) revert Errors.NotInEmergencyMode();
        _unpause();
        emit EmergencyModeDisabled();
    }

    /**
     * @dev Calculate ETH amount based on input token amount using appropriate Chainlink price feed.
     * @param token Input token address.
     * @param amount Amount of input token (in token's native decimals).
     * @return ethAmount Amount of ETH (18 decimals).
     */
    function calculateEthAmount(address token, uint256 amount) public view returns (uint256) {
        if (amount == 0) revert Errors.ZeroAmount();
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported();

        PaymentTokenConfig memory config = paymentTokens[token];
        // Retrieve price data from the token's price feed
        (uint80 roundId, int256 price, , uint256 updatedAt, ) = config.priceFeed.latestRoundData();

        if (roundId < 1) revert Errors.InvalidEthRoundId();
        if (price <= 0) revert Errors.InvalidEthPrice();
        if (block.timestamp - updatedAt > 30 minutes) revert Errors.StalePrice();

        // Calculate scaling factor:
        // We want F such that (amount * F) has (d + log10(F)) decimals,
        // and when divided by price (8 decimals) the result has 18 decimals.
        // Thus, F = 10^(26 - config.decimals) because 26 = 18 + 8.
        uint256 scalingFactor = 10 ** (26 - config.decimals);

        // Prevent potential overflow: ensure that (amount * scalingFactor) does not overflow when divided by price.
        if (uint256(price) >= type(uint256).max / scalingFactor) revert Errors.PriceOverflow();

        unchecked {
            return (amount * scalingFactor) / uint256(price);
        }
    }

    /**
     * @dev Get all supported payment tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        uint256 length = _supportedTokens.length();
        address[] memory tokens = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            tokens[i] = _supportedTokens.at(i);
        }
        return tokens;
    }

    /**
     * @dev Find the vault with sufficient ETH balance.
     */
    function findBestVault(
        uint256 requiredEth
    ) public view returns (address vault, uint256 balance) {
        uint256 vaultCount = vaultFactory.getVaultCountByOwner(address(this));
        if (vaultCount == 0) revert Errors.VaultNotFound();

        // Try to find a suitable vault starting with the most recent
        (address bestVault, uint256 bestBalance) = _findBestVaultInternal(requiredEth);

        // If we found a suitable vault, return it
        if (bestBalance >= requiredEth) {
            return (bestVault, bestBalance);
        }

        // Check all other vaults
        (address selectedVault, uint256 selectedBalance, uint256 totalBalance) = _checkAllVaults(
            requiredEth,
            bestVault,
            bestBalance
        );

        // If we found a suitable vault in the iteration
        if (selectedBalance >= requiredEth) {
            return (selectedVault, selectedBalance);
        }

        // If no vault has sufficient balance
        if (totalBalance < requiredEth) {
            revert Errors.InsufficientBalance();
        }

        // If total balance is sufficient but no single vault has enough
        revert Errors.VaultBalanceDistributionNeeded();
    }

    /**
     * @dev Internal function to find the best vault based on balance requirements
     */
    function _findBestVaultInternal(
        uint256 requiredEth
    ) internal view returns (address bestVault, uint256 bestBalance) {
        bestVault = address(0);
        bestBalance = 0;
        uint256 totalBalance = 0;

        // First check the most recently created vault
        address lastVault = vaultFactory.getLastVaultByOwner(address(this));
        if (lastVault != address(0)) {
            uint256 lastVaultBalance = address(payable(lastVault)).balance;
            totalBalance = lastVaultBalance;

            if (lastVaultBalance >= requiredEth) {
                return (lastVault, lastVaultBalance);
            }

            if (lastVaultBalance > bestBalance) {
                bestVault = lastVault;
                bestBalance = lastVaultBalance;
            }
        }

        return (bestVault, bestBalance);
    }

    /**
     * @dev Internal function to check all vaults for sufficient balance
     */
    function _checkAllVaults(
        uint256 requiredEth,
        address lastVault,
        uint256 initialTotalBalance
    ) internal view returns (address vault, uint256 balance, uint256 totalBalance) {
        totalBalance = initialTotalBalance;
        vault = address(0);
        balance = 0;

        uint256 vaultCount = vaultFactory.getVaultCountByOwner(address(this));
        for (uint256 i = 0; i < vaultCount; i++) {
            address currentVault = vaultFactory.getVaultByOwnerAndIndex(address(this), i);
            if (currentVault == lastVault) continue;

            uint256 vaultBalance = address(payable(currentVault)).balance;
            totalBalance += vaultBalance;

            if (vaultBalance >= requiredEth) {
                return (currentVault, vaultBalance, totalBalance);
            }

            if (vaultBalance > balance) {
                vault = currentVault;
                balance = vaultBalance;
            }
        }

        return (vault, balance, totalBalance);
    }

    /**
     * @dev Internal function to add or update a payment token
     */
    function _addPaymentToken(address token, address priceFeed) internal {
        if (token == address(0) || priceFeed == address(0)) revert Errors.InvalidAddress();

        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        if (!paymentTokens[token].isSupported) {
            _supportedTokens.add(token);
        }

        paymentTokens[token] = PaymentTokenConfig({
            isSupported: true,
            decimals: tokenDecimals,
            priceFeed: AggregatorV3Interface(priceFeed)
        });

        emit PaymentTokenUpdated(token, tokenDecimals, priceFeed);
    }

    /**
     * @dev Internal function to execute token exchange for ETH
     */
    function _executeExchange(address token, uint256 amount, address destination) internal {
        // Use default token if none specified
        address tokenToUse = token == address(0) ? defaultToken : token;
        if (!paymentTokens[tokenToUse].isSupported) revert Errors.TokenNotSupported();

        // Validate inputs
        if (destination == address(this)) revert Errors.InvalidDestination();
        if (amount < minDepositAmount) revert Errors.AmountBelowMinimum();
        if (amount > maxDepositAmount) revert Errors.AmountAboveMaximum();

        // Check rate limit
        uint256 currentBlock = block.number;
        emit RateLimitCheck(currentBlock, _lastProcessedBlock, depositsPerBlock[currentBlock]);

        if (_lastProcessedBlock < currentBlock) {
            _lastProcessedBlock = currentBlock;
            depositsPerBlock[currentBlock] = 1;
            emit RateLimitUpdated(currentBlock, 1);
        } else {
            depositsPerBlock[currentBlock]++;
            emit RateLimitUpdated(currentBlock, depositsPerBlock[currentBlock]);
            if (depositsPerBlock[currentBlock] > MAX_DEPOSITS_PER_BLOCK)
                revert Errors.RateLimitExceeded();
        }

        uint256 ethAmount = calculateEthAmount(tokenToUse, amount);
        address effectiveDestination = destination == address(0) ? msg.sender : destination;

        // Find vault with sufficient ETH balance
        (address vault, ) = findBestVault(ethAmount);

        // Transfer and deposit
        IERC20(tokenToUse).safeTransferFrom(msg.sender, address(this), amount);
        SafeERC20.forceApprove(IERC20(tokenToUse), vault, amount);
        Vault(payable(vault)).depositToken(tokenToUse, amount);

        // Use ETH transfer from Vault
        Vault(payable(vault)).sendEth(effectiveDestination, ethAmount);

        emit DepositProcessed(msg.sender, effectiveDestination, tokenToUse, amount, ethAmount);
    }

    /**
     * @dev UUPS Upgradeable function
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
