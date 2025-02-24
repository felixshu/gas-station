// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IVault
 * @dev Interface for the Vault contract
 */
interface IVault {
    // Standard events for deposits/withdrawals
    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);

    // Emergency events
    event EmergencyPaused();
    event EmergencyUnpaused();
    event EmergencyRecovery(address indexed token, uint256 amount, address indexed to);

    // Whitelist events
    event WhitelistSet(address indexed whitelist);
    event GasStationSet(address indexed gasStation);

    function setTokenWhitelist(address _whitelist) external;
    function setGasStation(address _gasStation) external;
    function initialize(address owner_, address whitelist_) external;
}
