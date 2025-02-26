// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVault
 * @dev Interface for the Vault contract
 */
interface IVault {
    // Events
    event WhitelistSet(address indexed whitelist);
    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event EmergencyPaused();
    event EmergencyUnpaused();
    event EmergencyRecovery(address indexed token, uint256 amount, address indexed to);
    event EthSent(address indexed destination, uint256 amount);

    // Functions
    function initialize(address owner_, address whitelist_) external;
    function setTokenWhitelist(address _whitelist) external;
    function setGasStation(address _gasStation) external;
    function depositEth() external payable;
    function depositToken(address token, uint256 amount) external;
    function withdrawEth(uint256 amount, address to) external;
    function withdrawToken(address token, uint256 amount, address to) external;
    function sendEth(address destination, uint256 amount) external;
    function emergencyPause() external;
    function emergencyUnpause() external;
    function emergencyRecoverToken(address token, uint256 amount, address to) external;
    function emergencyRecoverEth(uint256 amount, address to) external;
}
