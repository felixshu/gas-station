// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IGasOptimizer
 * @dev Interface for the GasOptimizer contract that handles EIP-1559 transactions
 */
interface IGasOptimizer {
    /**
     * @dev Send ETH to a destination address using EIP-1559 transaction type.
     * @param destination The address to send ETH to
     * @param amount The amount of ETH to send
     * @param maxPriorityFeePerGas Max priority fee per gas (in wei)
     * @param maxFeePerGas Max fee per gas (in wei)
     * @return success Whether the transaction was successful
     */
    function sendEthEIP1559(
        address destination,
        uint256 amount,
        uint256 maxPriorityFeePerGas,
        uint256 maxFeePerGas
    ) external returns (bool success);

    /**
     * @dev Get the current recommended gas parameters for EIP-1559 transactions.
     * @return baseFee The current base fee
     * @return maxPriorityFeePerGas The recommended max priority fee per gas
     * @return maxFeePerGas The recommended max fee per gas
     */
    function getGasParameters() external view returns (
        uint256 baseFee,
        uint256 maxPriorityFeePerGas,
        uint256 maxFeePerGas
    );
}