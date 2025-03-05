// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { Errors } from "./libraries/Errors.sol";
import { IGasStation } from "./interfaces/IGasStation.sol";
import { VaultFactory } from "./VaultFactory.sol";
import { Vault } from "./Vault.sol";
import { PaymentTokenConfig } from "./types/PaymentTypes.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

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
    // Structs
    // ======================================================
    // @dev Rate limit tracking struct - packed into one slot
    struct RateLimit {
        uint32 blockNumber;
        uint32 count;
    }

    // @dev Fee tier structure
    struct FeeTier {
        uint256 minAmount; // Minimum amount for this tier
        uint256 feeBps; // Fee in basis points (1% = 100 bps)
        bool isActive; // Whether this tier is active
    }

    // @dev Fee configuration
    struct FeeConfig {
        uint256 maxFeeBps; // Maximum allowed fee in basis points
        address feeCollector; // Address to collect fees
        bool feeEnabled; // Whether fee collection is enabled
    }

    // ======================================================
    // State Variables
    // ======================================================
    // @dev ETH/USD price feed
    AggregatorV3Interface public ethUsdPriceFeed;
    // @dev Vault factory contract
    VaultFactory public vaultFactory;
    // @dev Maximum number of vaults
    uint256 public constant MAX_VAULTS = 50; // Limit number of vaults for gas efficiency
    // @dev Minimum deposit amount (in token decimals)
    uint128 public minDepositAmount;
    // @dev Maximum deposit amount (in token decimals)
    uint128 public maxDepositAmount;
    // @dev Maximum deposits per block
    uint256 public constant MAX_DEPOSITS_PER_BLOCK = 10;

    // @dev Rate limit data
    RateLimit private _rateLimit;

    // @dev Mapping of payment token address to its configuration
    mapping(address => PaymentTokenConfig) public paymentTokens;

    // @dev List of supported payment tokens for iteration
    EnumerableSet.AddressSet private _supportedTokens;

    // @dev Default payment token address (e.g. USDC)
    address public defaultToken;

    // @dev Price feed decimals
    uint256 public constant PRICE_FEED_DECIMALS = 8;

    // @dev Fee tiers for each payment token
    mapping(address => FeeTier[]) public feeTiers;
    // @dev Fee configuration
    FeeConfig public feeConfig;
    // @dev User's total volume for each token
    mapping(address => mapping(address => uint256)) public userVolumes;
    // @dev Total fees collected per token
    mapping(address => uint256) public totalFeesCollected;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract.
     * @param params Initialization parameters
     */
    function initialize(InitParams calldata params) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        if (params.defaultToken == address(0)) revert Errors.InvalidAddress(params.defaultToken);
        if (params.defaultPriceFeed == address(0))
            revert Errors.InvalidAddress(params.defaultPriceFeed);
        if (params.vaultFactory == address(0)) revert Errors.InvalidAddress(params.vaultFactory);

        ethUsdPriceFeed = AggregatorV3Interface(params.defaultPriceFeed);
        vaultFactory = VaultFactory(params.vaultFactory);
        minDepositAmount = params.minDepositAmount;
        maxDepositAmount = params.maxDepositAmount;
        defaultToken = params.defaultToken;

        // Initialize fee configuration
        feeConfig = FeeConfig({
            maxFeeBps: 50, // 0.5% default max fee
            feeCollector: msg.sender, // Owner collects fees by default
            feeEnabled: true
        });

        // Initialize default fee tiers
        feeTiers[params.defaultToken].push(
            FeeTier({
                minAmount: 0,
                feeBps: 50, // 0.5% for 0-100 USDC
                isActive: true
            })
        );
        feeTiers[params.defaultToken].push(
            FeeTier({
                minAmount: 100 * 10 ** 6, // 100 USDC (6 decimals)
                feeBps: 40, // 0.4% for 100-500 USDC
                isActive: true
            })
        );
        feeTiers[params.defaultToken].push(
            FeeTier({
                minAmount: 500 * 10 ** 6, // 500 USDC (6 decimals)
                feeBps: 30, // 0.3% for 500+ USDC
                isActive: true
            })
        );

        _addPaymentToken(params.defaultToken, params.defaultPriceFeed);
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
        if (!paymentTokens[_newDefaultToken].isSupported)
            revert Errors.TokenNotSupported(_newDefaultToken);
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
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported(token);

        delete paymentTokens[token];
        _supportedTokens.remove(token);

        emit PaymentTokenRemoved(token);
    }

    /**
     * @dev Exchange tokens for ETH using regular approve/transferFrom pattern.
     * @param params Exchange parameters
     */
    function exchange(ExchangeParams calldata params) external nonReentrant whenNotPaused {
        _executeExchange(params.token, params.amount, params.destination);
    }

    /**
     * @dev Exchange tokens for ETH using permit for approval.
     * @param params Permit parameters containing exchange details and signature
     */
    function exchangeWithPermit(PermitParams calldata params) external nonReentrant whenNotPaused {
        // Validate deadline
        if (params.deadline < block.timestamp)
            revert Errors.ExpiredDeadline(params.deadline, block.timestamp);

        // Get the token address from the exchange params
        address tokenToUse = params.exchange.token == address(0)
            ? defaultToken
            : params.exchange.token;

        // Call the permit function on the token
        IERC20Permit(tokenToUse).permit(
            msg.sender, // owner
            address(this), // spender
            params.exchange.amount, // value
            params.deadline, // deadline
            params.v, // v
            params.r, // r
            params.s // s
        );

        // Execute the exchange now that approval is granted via permit
        _executeExchange(
            params.exchange.token,
            params.exchange.amount,
            params.exchange.destination
        );
    }

    /**
     * @dev Set the vault factory address.
     */
    function setVaultFactory(address _vaultFactory) external nonReentrant onlyOwner {
        if (_vaultFactory == address(0)) revert Errors.InvalidAddress(address(0));
        vaultFactory = VaultFactory(_vaultFactory);
        emit VaultFactorySet(_vaultFactory);
    }

    /**
     * @dev Set the gas station address in a Vault contract.
     * @param vault The vault address
     * @param gasStation The gas station address
     */
    function setVaultGasStation(address vault, address gasStation) external nonReentrant onlyOwner {
        if (vault == address(0) || gasStation == address(0))
            revert Errors.InvalidAddress(address(0));
        Vault(payable(vault)).setGasStation(gasStation);
    }

    /**
     * @dev Emergency withdraw any ERC20 token.
     * @param params Emergency withdrawal parameters
     */
    function emergencyWithdrawToken(
        WithdrawalParams calldata params
    ) external nonReentrant onlyOwner {
        if (!paused()) revert Errors.NotInEmergencyMode();
        if (params.token == address(0) || params.to == address(0))
            revert Errors.InvalidAddress(address(0));
        IERC20 tokenContract = IERC20(params.token);
        uint256 balance = tokenContract.balanceOf(address(this));
        if (params.amount > balance)
            revert Errors.InsufficientBalance(address(this), balance, params.amount);
        tokenContract.safeTransfer(params.to, params.amount);
        emit EmergencyWithdrawal(params.token, params.amount, params.to);
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
    function calculateEthAmount(address token, uint256 amount) external view returns (uint256) {
        return _calculateEthAmount(token, amount);
    }

    /**
     * @dev Debug function to get the scaling factor for a token
     */
    function getScalingFactor(address token) external view returns (uint64) {
        return paymentTokens[token].scalingFactor;
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
    ) external view returns (address vault, uint256 balance) {
        return _findBestVault(requiredEth);
    }

    /**
     * @dev Internal function to add or update a payment token
     */
    function _addPaymentToken(address token, address priceFeed) internal {
        if (token == address(0) || priceFeed == address(0))
            revert Errors.InvalidAddress(address(0));

        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        // For USDC with 6 decimals and ETH price of $2000 (with 8 decimals):
        // 2000 USDC (2000 * 10^6) should equal 1 ETH (10^18)
        // So 2000 * 10^6 * scalingFactor / (2000 * 10^8) = 10^18
        // This means scalingFactor should be 10^20

        // For a token with decimals 'd', to get 18 decimals in the result:
        // amount * scalingFactor / price = ethAmount (18 decimals)
        // where price has 8 decimals (PRICE_FEED_DECIMALS)
        // So: scalingFactor = 10^(18 + 8) / 10^d = 10^(26 - d)
        uint64 scalingFactor;
        unchecked {
            scalingFactor = uint64(10 ** (26 - tokenDecimals));
        }

        // Check if token is already supported to avoid unnecessary storage operations
        bool isAlreadySupported = paymentTokens[token].isSupported;
        if (!isAlreadySupported) {
            _supportedTokens.add(token);
        }

        // Create token config in memory before writing to storage
        PaymentTokenConfig memory config = PaymentTokenConfig({
            isSupported: true,
            decimals: tokenDecimals,
            priceFeed: priceFeed,
            scalingFactor: scalingFactor
        });

        // Write to storage once
        paymentTokens[token] = config;

        emit PaymentTokenUpdated(token, tokenDecimals, priceFeed);
    }

    /**
     * @dev Internal function to execute token exchange for ETH
     */
    function _executeExchange(address token, uint256 amount, address destination) internal {
        // Cache storage variables to save gas
        address _defaultToken = defaultToken;
        uint128 _minDepositAmount = minDepositAmount;
        uint128 _maxDepositAmount = maxDepositAmount;

        // Use default token if none specified
        address tokenToUse = token == address(0) ? _defaultToken : token;

        // Load token config to memory to avoid multiple storage reads
        PaymentTokenConfig memory config = paymentTokens[tokenToUse];
        if (!config.isSupported) revert Errors.TokenNotSupported(token);

        // Validate inputs
        if (destination == address(this)) revert Errors.InvalidDestination(destination);
        if (amount < _minDepositAmount) revert Errors.AmountBelowMinimum(amount, _minDepositAmount);
        if (amount > _maxDepositAmount) revert Errors.AmountAboveMaximum(amount, _maxDepositAmount);

        // Check and update rate limit
        _checkAndUpdateRateLimit();

        // Calculate fee if enabled
        uint256 feeAmount = 0;
        if (feeConfig.feeEnabled) {
            feeAmount = calculateFee(tokenToUse, amount);
            if (feeAmount > 0) {
                totalFeesCollected[tokenToUse] += feeAmount;
                emit FeesCollected(tokenToUse, feeAmount);
            }
        }

        // Update user volume
        userVolumes[msg.sender][tokenToUse] += amount;

        // Calculate ETH amount and determine effective destination
        uint256 ethAmount = _calculateEthAmount(tokenToUse, amount);
        address effectiveDestination = destination == address(0) ? msg.sender : destination;

        // Find vault with sufficient ETH balance
        (address vault, ) = _findBestVault(ethAmount);

        // Handle token deposit
        _handleTokenDeposit(tokenToUse, amount, vault);

        // Send ETH to destination
        if (ethAmount > 0) {
            Vault(payable(vault)).sendEth(
                IVault.EthParams({
                    amount: ethAmount,
                    recipient: effectiveDestination,
                    user: address(0)
                })
            );
        }

        emit DepositProcessed(msg.sender, tokenToUse, amount, ethAmount, effectiveDestination);
    }

    /**
     * @dev Helper function to check and update rate limit
     */
    function _checkAndUpdateRateLimit() internal {
        uint32 currentBlock = uint32(block.number);
        // Load rate limit data to memory to avoid multiple storage reads
        RateLimit memory rateLimit = _rateLimit;

        emit RateLimitCheck(currentBlock, rateLimit.blockNumber, rateLimit.count);

        // Update rate limit in memory first
        if (rateLimit.blockNumber < currentBlock) {
            rateLimit.blockNumber = currentBlock;
            rateLimit.count = 1;
        } else {
            unchecked {
                rateLimit.count++;
            }
            if (rateLimit.count > MAX_DEPOSITS_PER_BLOCK)
                revert Errors.RateLimitExceeded(rateLimit.count, MAX_DEPOSITS_PER_BLOCK);
        }

        // Write back to storage only once
        _rateLimit = rateLimit;
        emit RateLimitUpdated(currentBlock, rateLimit.count);
    }

    /**
     * @dev Helper function to handle token deposit
     */
    function _handleTokenDeposit(address tokenToUse, uint256 amount, address vault) internal {
        if (tokenToUse != address(0)) {
            // First transfer tokens from user to GasStation
            IERC20 token = IERC20(tokenToUse);
            token.safeTransferFrom(msg.sender, address(this), amount);

            // Approve vault to spend tokens
            token.forceApprove(vault, amount);

            // Transfer tokens from GasStation to vault
            Vault(payable(vault)).depositToken(
                IVault.TokenParams({
                    token: tokenToUse,
                    amount: amount,
                    recipient: address(0),
                    user: address(0)
                })
            );
        }
    }

    /**
     * @dev UUPS Upgradeable function
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Internal implementation of findBestVault
     */
    function _findBestVault(
        uint256 requiredEth
    ) internal view returns (address vault, uint256 balance) {
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
            revert Errors.InsufficientBalance(address(this), totalBalance, requiredEth);
        }

        // If total balance is sufficient but no single vault has enough
        revert Errors.VaultBalanceDistributionNeeded(totalBalance, requiredEth);
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

            unchecked {
                totalBalance += vaultBalance;
            }

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
     * @dev Internal implementation of calculateEthAmount
     */
    function _calculateEthAmount(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) revert Errors.ZeroAmount();

        // Load token config to memory to avoid multiple storage reads
        PaymentTokenConfig memory config = paymentTokens[token];
        if (!config.isSupported) revert Errors.TokenNotSupported(token);

        // Retrieve price data from the token's price feed
        (uint80 roundId, int256 price, , uint256 updatedAt, ) = AggregatorV3Interface(
            config.priceFeed
        ).latestRoundData();

        if (roundId < 1) revert Errors.InvalidEthRoundId(roundId);
        if (price <= 0) revert Errors.InvalidEthPrice(price);
        if (block.timestamp - updatedAt > 30 minutes)
            revert Errors.StalePrice(updatedAt, block.timestamp, 30 minutes);

        // Special case for the test: 2000 USDC (with 6 decimals) should equal 1 ETH when ETH price is $2000
        // This is a direct conversion based on USD value
        // amount in token * (1 ETH / ETH price in USD) = amount in ETH

        // Convert to same decimals: amount in token * 10^(18 - token decimals) = amount in token with 18 decimals
        uint256 amountIn18Decimals = amount * (10 ** (18 - config.decimals));

        // Convert to ETH: amount in token with 18 decimals * 10^8 / ETH price in USD with 8 decimals
        // = amount in ETH with 18 decimals
        uint256 ethAmount = (amountIn18Decimals * (10 ** PRICE_FEED_DECIMALS)) / uint256(price);

        return ethAmount;
    }

    /**
     * @dev Set the minimum and maximum deposit amounts
     * @param _minDepositAmount The minimum deposit amount (in token decimals)
     * @param _maxDepositAmount The maximum deposit amount (in token decimals)
     */
    function setDepositLimits(
        uint128 _minDepositAmount,
        uint128 _maxDepositAmount
    ) external onlyOwner {
        // Ensure min is less than max
        if (_minDepositAmount >= _maxDepositAmount)
            revert Errors.InvalidDepositLimits(_minDepositAmount, _maxDepositAmount);

        minDepositAmount = _minDepositAmount;
        maxDepositAmount = _maxDepositAmount;

        emit DepositLimitsUpdated(_minDepositAmount, _maxDepositAmount);
    }

    /**
     * @dev Add a new fee tier for a token
     * @param token The token address
     * @param minAmount The minimum amount for this tier
     * @param feeBps The fee in basis points (1% = 100 bps)
     */
    function addFeeTier(address token, uint256 minAmount, uint256 feeBps) external onlyOwner {
        if (token == address(0)) revert Errors.InvalidAddress(token);
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported(token);
        if (feeBps > feeConfig.maxFeeBps) revert Errors.MaxFeeExceeded(feeBps, feeConfig.maxFeeBps);

        // Add new tier
        feeTiers[token].push(FeeTier({ minAmount: minAmount, feeBps: feeBps, isActive: true }));

        emit FeeTierAdded(token, minAmount, feeBps);
    }

    /**
     * @dev Update an existing fee tier
     * @param token The token address
     * @param tierIndex The index of the tier to update
     * @param minAmount The new minimum amount for this tier
     * @param feeBps The new fee in basis points
     */
    function updateFeeTier(
        address token,
        uint256 tierIndex,
        uint256 minAmount,
        uint256 feeBps
    ) external onlyOwner {
        if (token == address(0)) revert Errors.InvalidAddress(token);
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported(token);
        if (feeBps > feeConfig.maxFeeBps) revert Errors.MaxFeeExceeded(feeBps, feeConfig.maxFeeBps);
        if (tierIndex >= feeTiers[token].length) revert Errors.FeeTierNotFound(tierIndex);

        // Update tier
        feeTiers[token][tierIndex].minAmount = minAmount;
        feeTiers[token][tierIndex].feeBps = feeBps;

        emit FeeTierUpdated(token, tierIndex, minAmount, feeBps);
    }

    /**
     * @dev Remove a fee tier
     * @param token The token address
     * @param tierIndex The index of the tier to remove
     */
    function removeFeeTier(address token, uint256 tierIndex) external onlyOwner {
        if (token == address(0)) revert Errors.InvalidAddress(token);
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported(token);
        if (tierIndex >= feeTiers[token].length) revert Errors.FeeTierNotFound(tierIndex);

        // Remove tier by swapping with last element and popping
        uint256 lastIndex = feeTiers[token].length - 1;
        if (tierIndex != lastIndex) {
            feeTiers[token][tierIndex] = feeTiers[token][lastIndex];
        }
        feeTiers[token].pop();

        emit FeeTierRemoved(token, tierIndex);
    }

    /**
     * @dev Set the maximum allowed fee in basis points
     * @param maxFeeBps The maximum fee in basis points
     */
    function setMaxFeeBps(uint256 maxFeeBps) external onlyOwner {
        feeConfig.maxFeeBps = maxFeeBps;
        emit MaxFeeUpdated(maxFeeBps);
    }

    /**
     * @dev Set the fee collector address
     * @param feeCollector The new fee collector address
     */
    function setFeeCollector(address feeCollector) external onlyOwner {
        if (feeCollector == address(0)) revert Errors.InvalidAddress(feeCollector);
        feeConfig.feeCollector = feeCollector;
        emit FeeCollectorUpdated(feeCollector);
    }

    /**
     * @dev Toggle fee collection on/off
     * @param enabled Whether to enable or disable fee collection
     */
    function toggleFeeCollection(bool enabled) external onlyOwner {
        feeConfig.feeEnabled = enabled;
        emit FeeCollectionToggled(enabled);
    }

    /**
     * @dev Calculate the fee for a given token amount
     * @param token The token address
     * @param amount The amount to calculate fee for
     * @return feeAmount The fee amount in the same token
     */
    function calculateFee(address token, uint256 amount) public view returns (uint256) {
        if (!feeConfig.feeEnabled) return 0;
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported(token);

        // Get the applicable tier
        FeeTier memory tier = getApplicableTier(token, amount);
        if (!tier.isActive) return 0;

        // Calculate fee: amount * feeBps / 10000
        return (amount * tier.feeBps) / 10000;
    }

    /**
     * @dev Calculate the amount after fee deduction
     * @param token The token address
     * @param amount The original amount
     * @return amountAfterFee The amount after fee deduction
     */
    function calculateAmountAfterFee(
        address token,
        uint256 amount
    ) external view returns (uint256) {
        uint256 fee = calculateFee(token, amount);
        return amount - fee;
    }

    /**
     * @dev Get the applicable fee tier for a given token amount
     * @param token The token address
     * @param amount The amount to find tier for
     * @return The applicable fee tier
     */
    function getApplicableTier(address token, uint256 amount) public view returns (FeeTier memory) {
        FeeTier[] memory tiers = feeTiers[token];
        if (tiers.length == 0) return FeeTier({ minAmount: 0, feeBps: 0, isActive: false });

        // Find the highest applicable tier
        for (uint256 i = tiers.length; i > 0; i--) {
            if (amount >= tiers[i - 1].minAmount) {
                return tiers[i - 1];
            }
        }

        // If no tier applies, return the lowest tier
        return tiers[0];
    }

    /**
     * @dev Withdraw collected fees for a token
     * @param token The token to withdraw fees for
     */
    function withdrawFees(address token) external onlyOwner {
        if (token == address(0)) revert Errors.InvalidAddress(token);
        if (!paymentTokens[token].isSupported) revert Errors.TokenNotSupported(token);

        uint256 amount = totalFeesCollected[token];
        if (amount == 0) revert Errors.ZeroAmount();

        totalFeesCollected[token] = 0;
        IERC20(token).safeTransfer(feeConfig.feeCollector, amount);

        emit FeesWithdrawn(token, amount);
    }

    /**
     * @dev Get all fee tiers for a token
     * @param token The token address
     * @return The array of fee tiers
     */
    function getFeeTiers(address token) external view returns (FeeTier[] memory) {
        return feeTiers[token];
    }

    /**
     * @dev Get the total volume for a user and token
     * @param user The user address
     * @param token The token address
     * @return The total volume
     */
    function getUserVolume(address user, address token) external view returns (uint256) {
        return userVolumes[user][token];
    }

    /**
     * @dev Get the total fees collected for a token
     * @param token The token address
     * @return The total fees collected
     */
    function getTotalFeesCollected(address token) external view returns (uint256) {
        return totalFeesCollected[token];
    }
}
