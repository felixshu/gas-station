# Gas Station Smart Contracts

A decentralized gas fee payment system that allows users to pay for Ethereum gas fees using ERC20 tokens.

## Architecture

The system consists of several smart contracts working together to provide secure and efficient token-to-ETH conversion for gas payments:

```mermaid
graph TD
    A[GasStation] --> B[VaultFactory]
    B --> C[Vault 1]
    B --> D[Vault 2]
    B --> E[Vault n]
    A --> F[TokenWhitelist]
    C & D & E --> G[Token Deposits]
    C & D & E --> H[ETH Balance]
```

### Core Components

#### GasStation

- Main entry point for users
- Handles token deposits and ETH distribution
- Manages payment tokens and price feeds
- Features:
  - Multi-token support with Chainlink price feeds
  - Permit-based token approvals
  - Rate limiting per block
  - Emergency pause mechanism

#### VaultFactory

- Creates and manages vault instances
- Maintains registry of all vaults
- Handles vault ownership and access control
- Features:
  - Upgradeable vault implementation
  - Owner-based vault creation
  - Efficient vault querying

#### Vault

- Stores and manages token/ETH balances
- Handles token deposits and ETH withdrawals
- Features:
  - Token whitelist integration
  - Emergency recovery mechanisms
  - Balance tracking per user/token

#### TokenWhitelist

- Manages allowed tokens
- Security layer for token operations
- Centralized token validation

## Key Features

### Vault Management

- Dynamic vault creation based on usage
- Automatic vault selection based on ETH balance
- Maximum vault limit for gas efficiency
- Balance distribution across vaults

### Security

- Reentrancy protection
- Pausable contracts
- Emergency withdrawal mechanisms
- Owner-only administrative functions
- Token whitelist validation

### Gas Optimization

- Efficient vault querying
- Minimal array usage
- Optimized balance checks
- Rate limiting per block

## Contract Interactions

1. User initiates token deposit with `exchangeWithPermit`
2. GasStation finds suitable vault using `findBestVault`
3. Tokens are transferred to the vault
4. ETH is sent to the user's destination address

## Development

### Prerequisites

- Node.js >= 16
- Hardhat
- OpenZeppelin Contracts

### Setup

```bash
npm install
npx hardhat compile
```

### Testing

```bash
npx hardhat test
```

### Deployment

```bash
npx hardhat deploy --network <network>
```

## Security Considerations

### Rate Limiting

- Maximum deposits per block: 10
- Configurable deposit limits
- Price feed staleness checks

### Emergency Procedures

1. Owner can pause contracts
2. Withdrawals remain available during pause
3. Emergency token/ETH recovery
4. Balance protection during recovery

## Interface Integration

### Key Functions

```solidity
// Deposit tokens, receive ETH
function exchangeWithPermit(
    address token,
    uint256 amount,
    address destination,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) external;

// Calculate ETH amount for token deposit
function calculateEthAmount(
    address token,
    uint256 amount
) external view returns (uint256);
```

## Error Handling

The system uses custom errors for clear error reporting:

- `InsufficientBalance`
- `VaultNotFound`
- `TokenNotSupported`
- `VaultBalanceDistributionNeeded`

## Upgradeability

All core contracts are upgradeable using the UUPS pattern:

- GasStation
- Vault
- VaultFactory
- TokenWhitelist

## License

MIT
