// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IGasOptimizer.sol";
import "./libraries/Errors.sol";

/**
 * @title GasOptimizer
 * @dev Contract for optimizing gas usage with EIP-1559 transactions
 */
contract GasOptimizer is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IGasOptimizer
{
    // Default gas parameters
    uint256 public defaultMaxPriorityFeePerGas;
    uint256 public defaultMaxFeePerGas;

    // Gas parameter bounds
    uint256 public minPriorityFeePerGas;
    uint256 public maxPriorityFeePerGas;

    // Dynamic fee adjustment
    bool public dynamicFeeEnabled;

    // Gas price oracle
    address public gasPriceOracle;

    // Events
    event EthSentEIP1559(
        address indexed destination,
        uint256 amount,
        uint256 maxPriorityFeePerGas,
        uint256 maxFeePerGas
    );
    event GasParametersUpdated(
        uint256 defaultMaxPriorityFeePerGas,
        uint256 defaultMaxFeePerGas,
        uint256 minPriorityFeePerGas,
        uint256 maxPriorityFeePerGas
    );
    event DynamicFeeToggled(bool enabled);
    event GasPriceOracleSet(address indexed gasPriceOracle);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     * @param _defaultMaxPriorityFeePerGas Default max priority fee per gas (in wei)
     * @param _defaultMaxFeePerGas Default max fee per gas (in wei)
     * @param _minPriorityFeePerGas Minimum priority fee per gas (in wei)
     * @param _maxPriorityFeePerGas Maximum priority fee per gas (in wei)
     */
    function initialize(
        uint256 _defaultMaxPriorityFeePerGas,
        uint256 _defaultMaxFeePerGas,
        uint256 _minPriorityFeePerGas,
        uint256 _maxPriorityFeePerGas
    ) public initializer {
        __Ownable_init(msg.sender);
        __Pausable_init();
        __UUPSUpgradeable_init();

        defaultMaxPriorityFeePerGas = _defaultMaxPriorityFeePerGas;
        defaultMaxFeePerGas = _defaultMaxFeePerGas;
        minPriorityFeePerGas = _minPriorityFeePerGas;
        maxPriorityFeePerGas = _maxPriorityFeePerGas;

        dynamicFeeEnabled = false;
    }

    /**
     * @dev Send ETH to a destination address using EIP-1559 transaction type.
     * @param destination The address to send ETH to
     * @param amount The amount of ETH to send
     * @param _maxPriorityFeePerGas Max priority fee per gas (in wei)
     * @param _maxFeePerGas Max fee per gas (in wei)
     * @return success Whether the transaction was successful
     */
    function sendEthEIP1559(
        address destination,
        uint256 amount,
        uint256 _maxPriorityFeePerGas,
        uint256 _maxFeePerGas
    ) external whenNotPaused returns (bool success) {
        if (destination == address(0)) revert Errors.InvalidAddress();
        if (amount == 0) revert Errors.InvalidAmount();

        // Use provided gas parameters or defaults
        uint256 priorityFee = _maxPriorityFeePerGas > 0
            ? _maxPriorityFeePerGas
            : defaultMaxPriorityFeePerGas;
        uint256 maxFee = _maxFeePerGas > 0 ? _maxFeePerGas : defaultMaxFeePerGas;

        // Apply bounds if dynamic fee is enabled
        if (dynamicFeeEnabled) {
            priorityFee = _boundPriorityFee(priorityFee);

            // Ensure maxFee is at least baseFee + priorityFee
            uint256 baseFee = block.basefee;
            maxFee = maxFee < (baseFee + priorityFee) ? (baseFee + priorityFee) : maxFee;
        }

        // Send ETH using EIP-1559 parameters
        (success, ) = destination.call{ value: amount, gas: 30000 }("");

        if (success) {
            emit EthSentEIP1559(destination, amount, priorityFee, maxFee);
        }

        return success;
    }

    /**
     * @dev Get the current recommended gas parameters for EIP-1559 transactions.
     * @return currentBaseFee The current base fee
     * @return recommendedPriorityFee The recommended max priority fee per gas
     * @return recommendedMaxFee The recommended max fee per gas
     */
    function getGasParameters()
        external
        view
        returns (uint256 currentBaseFee, uint256 recommendedPriorityFee, uint256 recommendedMaxFee)
    {
        currentBaseFee = block.basefee;

        // Use dynamic fee if enabled, otherwise use defaults
        if (dynamicFeeEnabled) {
            recommendedPriorityFee = _boundPriorityFee(defaultMaxPriorityFeePerGas);
            recommendedMaxFee = currentBaseFee + recommendedPriorityFee;
        } else {
            recommendedPriorityFee = defaultMaxPriorityFeePerGas;
            recommendedMaxFee = defaultMaxFeePerGas;
        }

        return (currentBaseFee, recommendedPriorityFee, recommendedMaxFee);
    }

    /**
     * @dev Update gas parameters
     * @param _defaultMaxPriorityFeePerGas Default max priority fee per gas (in wei)
     * @param _defaultMaxFeePerGas Default max fee per gas (in wei)
     * @param _minPriorityFeePerGas Minimum priority fee per gas (in wei)
     * @param _maxPriorityFeePerGas Maximum priority fee per gas (in wei)
     */
    function updateGasParameters(
        uint256 _defaultMaxPriorityFeePerGas,
        uint256 _defaultMaxFeePerGas,
        uint256 _minPriorityFeePerGas,
        uint256 _maxPriorityFeePerGas
    ) external onlyOwner {
        if (_minPriorityFeePerGas > _maxPriorityFeePerGas) revert Errors.InvalidParameters();

        defaultMaxPriorityFeePerGas = _defaultMaxPriorityFeePerGas;
        defaultMaxFeePerGas = _defaultMaxFeePerGas;
        minPriorityFeePerGas = _minPriorityFeePerGas;
        maxPriorityFeePerGas = _maxPriorityFeePerGas;

        emit GasParametersUpdated(
            _defaultMaxPriorityFeePerGas,
            _defaultMaxFeePerGas,
            _minPriorityFeePerGas,
            _maxPriorityFeePerGas
        );
    }

    /**
     * @dev Toggle dynamic fee adjustment
     * @param enabled Whether dynamic fee adjustment should be enabled
     */
    function toggleDynamicFee(bool enabled) external onlyOwner {
        dynamicFeeEnabled = enabled;
        emit DynamicFeeToggled(enabled);
    }

    /**
     * @dev Set gas price oracle address
     * @param _gasPriceOracle Address of the gas price oracle
     */
    function setGasPriceOracle(address _gasPriceOracle) external onlyOwner {
        if (_gasPriceOracle == address(0)) revert Errors.InvalidAddress();
        gasPriceOracle = _gasPriceOracle;
        emit GasPriceOracleSet(_gasPriceOracle);
    }

    /**
     * @dev Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Bound priority fee within min and max limits
     * @param priorityFee The priority fee to bound
     * @return The bounded priority fee
     */
    function _boundPriorityFee(uint256 priorityFee) internal view returns (uint256) {
        if (priorityFee < minPriorityFeePerGas) {
            return minPriorityFeePerGas;
        } else if (priorityFee > maxPriorityFeePerGas) {
            return maxPriorityFeePerGas;
        }
        return priorityFee;
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Receive function to accept ETH
     */
    receive() external payable {}
}
