// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct PaymentTokenConfig {
    bool isSupported;
    uint8 decimals;
    address priceFeed;
    uint64 scalingFactor;
}
