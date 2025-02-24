// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

struct PaymentTokenConfig {
    bool isSupported;
    uint8 decimals;
    AggregatorV3Interface priceFeed;
}
