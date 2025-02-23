# Ethereum Contract Development Plan

Contract: `GasStation.sol`

## 1. Project Setup

- **Initialize Hardhat Project:**
  - Create a new project directory and initialize with `npx hardhat`.
  - Choose the "Create a basic sample project" option.
  - Install dependencies, including Hardhat, ethers.js, and testing libraries (Mocha, Chai).

- **Install OpenZeppelin Contracts:**
  - Add OpenZeppelin's library to leverage audited implementations:
    `npm install @openzeppelin/contracts-upgradeable`

- **Version Control & CI/CD:**
  - Set up Git for version control.
  - Configure continuous integration (e.g., GitHub Actions) to run tests on each push.

---

## 2. Smart Contract Architecture & Design

- **Core Contract Features:**
  - **USDC Deposit Handler:**
    Create functions to accept USDC deposits using the standard ERC-20 interface. Use OpenZeppelin's ERC20 interface for safe token transfers.
  - **Optional Destination Parameter:**
    Implement a deposit function that accepts an optional destination wallet address. If no address is provided, default to using `msg.sender`.
  - **Gas Fee Credit Transfer:**
    Include functionality to trigger an ETH transfer (from a reserved pool) upon a valid deposit. If dynamic conversion is required, integrate with a Chainlink oracle.

- **Security Patterns:**
  - Use reentrancy guards (OpenZeppelin's `ReentrancyGuard`) to prevent common vulnerabilities.
  - Apply input validations and require statements to check deposit limits and validate wallet addresses.
  - Consider using the Ownable pattern for administrative controls (using OpenZeppelin's `Ownable`).

- **Upgradeable Contracts (Optional):**
  - If future updates are anticipated, consider using OpenZeppelin's upgradeable contract framework with the `@openzeppelin/hardhat-upgrades` plugin.

---

## 3. Development Steps

### 3.1 Contract Coding

- **Design and Write Contract(s):**
  - Create a primary contract (e.g., `GasStation.sol`) that encapsulates deposit handling and ETH transfers.
  - Import and extend OpenZeppelin contracts for ERC-20 interactions and security features.
  - Define state variables for tracking deposits, limits, and reserved ETH balance.

- **Implement Optional Destination Logic:**
  - Write the deposit function to accept an optional address parameter.
  - Include logic to verify if an address is provided; otherwise, assign `msg.sender` as the destination.

- **Chainlink Integration:**
  - Write helper functions to fetch conversion rates between USDC and ETH using Chainlink oracles.
  - Ensure that external calls are secure and follow best practices.

### 3.2 Local Testing

- **Unit Testing:**
  - Write comprehensive unit tests using Mocha/Chai in the `test` folder.
  - Test scenarios for:
    - Successful deposits with a specified destination.
    - Deposits where no destination is provided (defaulting to `msg.sender`).
    - Edge cases such as invalid addresses or out-of-bound deposit amounts.
  - Utilize Hardhat's network simulation for fast iteration.

- **Integration Testing:**
  - Create tests to simulate the complete deposit-to-transfer workflow.
  - Verify event logs and state changes after deposits and transfers.

---

## 4. Deployment and Integration

### 4.1 Deployment Scripts

- **Script Setup:**
  - Write deployment scripts in the `scripts` folder using Hardhat's deployment utilities.
  - Ensure the script deploys the contract to a local Hardhat network, followed by a testnet (e.g., Goerli).

- **Configuration:**
  - Manage network configurations in `hardhat.config.js`, including setting up private keys and provider URLs for testnets.

### 4.2 Frontend Integration

- **Interface with Ethers.js:**
  - Ensure that your frontend (telemetry UI) uses ethers.js to interact with the deployed contract.
  - Implement functions to read transaction statuses, wallet balances, and event logs.

- **Optional: TypeChain Integration:**
  - If using TypeScript in your frontend, generate type-safe contract bindings with TypeChain.

---

## 5. Security and Auditing

- **Internal Code Reviews:**
  - Conduct thorough internal reviews of the smart contract code and testing suites.
  - Verify that all critical paths (e.g., optional destination logic and ETH transfers) are well-tested.

- **Third-Party Audits:**
  - Plan for an external security audit of the smart contract before mainnet deployment.
  - Address any audit feedback and perform a re-audit if major changes are made.

- **Deployment Monitoring:**
  - Set up monitoring for smart contract events and potential anomalies post-deployment using tools like Tenderly or Etherscan alerts.

---

## 6. Roadmap and Milestones

1. **Phase 1: Development & Prototyping (Ethereum Testnet)**
   - Project setup, contract design, and initial coding.
   - Complete unit and integration testing on a local network.
   - Deploy to an Ethereum testnet (e.g., Goerli) for further testing.

2. **Phase 2: Security and Audit**
   - Conduct internal code reviews and comprehensive testing.
   - Engage a third-party auditor to review the contract.
   - Address any audit findings and update the contract accordingly.

3. **Phase 3: Mainnet Deployment & Monitoring**
   - Deploy the audited contract to Ethereum mainnet.
   - Integrate with the telemetry UI for real-time monitoring.
   - Monitor the contract performance and user transactions.

---

## Conclusion

This smart contract development plan provides a structured approach using Hardhat, OpenZeppelin libraries, and best practices for security and testing. It covers every stage—from initial project setup and coding to deployment and monitoring—ensuring that your gas station service is built on a solid, audited foundation.

---

Great! If each vault doesn't need to store specific tokens, we can simplify the architecture while maintaining scalability and flexibility. Here's the updated design:

---

## 1. **Multi-Vault Architecture**

### Design Overview

- **Unified Vaults:** Each vault is now a general-purpose container that can store multiple tokens, including ETH, USDC, and any future ERC20 tokens.
- **Dynamic Token Support:** Tokens are dynamically managed, allowing seamless addition or removal of supported tokens.
- **GasStation Router:** The `GasStation` contract acts as a router, directing deposits and withdrawals to the appropriate vault.

### Key Components

1. **VaultFactory:** Deploys and manages multiple generic vaults.
2. **Vault:** A flexible container that:
   - Holds multiple token balances.
   - Tracks user balances per token.
   - Facilitates deposits and withdrawals.
3. **GasStation:** Manages interactions, including:
   - Routing deposits and withdrawals.
   - Handling price conversions using Chainlink.
4. **TokenRegistry:** Whitelists supported tokens and ensures only approved tokens are used.

---

## 2. **Detailed Architecture**

### A. VaultFactory Contract

**Responsibilities:**

- Deploys new generic vaults.
- Manages a list of all deployed vaults.
- Associates vaults with owners, allowing multiple vaults per user.

**Key Functions:**

- `createVault()`: Deploys a new generic vault.
- `getVaultsByOwner(address owner)`: Returns all vaults owned by the given address.
- `getAllVaults()`: Returns all deployed vaults.

---

### B. Vault Contract

**Responsibilities:**

- Stores balances for multiple tokens, including ETH.
- Tracks user balances per token.
- Facilitates deposits and withdrawals for any supported token.
- Handles ETH natively using `receive()` and `fallback()`.

**Key Features:**

- **Multi-Token Support:** One vault can hold multiple ERC20 tokens and ETH.
- **Balance Tracking:** Maintains a mapping of user balances per token.
- **Security:** Uses `ReentrancyGuardUpgradeable` and `SafeERC20` for secure transfers.

---

### C. GasStation Contract (Enhanced)

**Responsibilities:**

- Acts as a router to:
  - Direct deposits to the correct vault.
  - Route withdrawals from the correct vault.
- Manages price conversions using Chainlink oracles.
- Supports flexible deposit and withdrawal logic for any whitelisted token.

**Key Features:**

- **Multi-Token Routing:** Directs deposits and withdrawals for multiple tokens.
- **Dynamic Price Conversion:** Uses Chainlink for real-time price data for all supported tokens.
- **Fee Mechanism:** Optionally charge deposit and withdrawal fees.

---

### D. TokenRegistry Contract

**Responsibilities:**

- Whitelists supported tokens.
- Maintains the list of tokens supported across all vaults.

**Key Functions:**

- `isTokenSupported(address token)`: Checks if a token is whitelisted.
- `addSupportedToken(address token)`: Adds a new token to the whitelist.
- `removeSupportedToken(address token)`: Removes a token from the whitelist.

---

## 3. **Smart Contract Implementation**

### A. VaultFactory

This contract manages the creation of vaults and keeps track of all deployed instances.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./Vault.sol";

contract VaultFactory {
    mapping(address => address[]) public userVaults;
    address[] public allVaults;

    event VaultCreated(address indexed owner, address vault);

    /**
     * @dev Create a new Vault and assign ownership to the sender
     */
    function createVault() external {
        Vault newVault = new Vault(msg.sender);
        userVaults[msg.sender].push(address(newVault));
        allVaults.push(address(newVault));
        emit VaultCreated(msg.sender, address(newVault));
    }

    /**
     * @dev Get all vaults created by a user
     */
    function getVaultsByOwner(address owner) external view returns (address[] memory) {
        return userVaults[owner];
    }

    /**
     * @dev Get all vaults deployed
     */
    function getAllVaults() external view returns (address[] memory) {
        return allVaults;
    }
}
```

---

### B. Vault

A generic vault supporting multiple tokens, including ETH and ERC20 tokens.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vault is ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    address public owner;
    mapping(address => mapping(address => uint256)) public balances;

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);

    constructor(address _owner) {
        owner = _owner;
    }

    /**
     * @dev Deposit ETH into the vault
     */
    function depositEth() external payable {
        balances[msg.sender][address(0)] += msg.value;
        emit Deposited(msg.sender, address(0), msg.value);
    }

    /**
     * @dev Deposit ERC20 tokens into the vault
     */
    function depositToken(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        balances[msg.sender][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, token, amount);
    }

    /**
     * @dev Withdraw ETH from the vault
     */
    function withdrawEth(uint256 amount) external nonReentrant {
        require(balances[msg.sender][address(0)] >= amount, "Insufficient balance");
        balances[msg.sender][address(0)] -= amount;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
        emit Withdrawn(msg.sender, address(0), amount);
    }

    /**
     * @dev Withdraw ERC20 tokens from the vault
     */
    function withdrawToken(address token, uint256 amount) external nonReentrant {
        require(balances[msg.sender][token] >= amount, "Insufficient balance");
        balances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    /**
     * @dev Fallback function to accept ETH
     */
    receive() external payable {
        balances[msg.sender][address(0)] += msg.value;
        emit Deposited(msg.sender, address(0), msg.value);
    }
}
```

---

## 4. **Benefits of Unified Vault Design**

- **Flexibility:** Each vault can store multiple tokens, reducing deployment complexity.
- **Scalability:** New tokens can be supported without deploying new vaults.
- **Simplicity:** Easier management of tokens and balances within fewer contracts.
- **Security:** Multi-token support is isolated within each vault, enhancing risk management.

---

## 5. **Advanced Features and Ideas**

### A. Yield Optimization

- Integrate yield farming strategies per vault using protocols like Aave or Compound.
- Allow the owner to select or switch yield strategies.

### B. Governance and Access Control

- Implement governance to manage supported tokens and fees.
- Introduce roles for managing vaults (e.g., admin, strategist, auditor).

### C. Fee Mechanisms

- Dynamic fee structure for deposits and withdrawals.
- Performance fee on yield earnings.

### D. Multi-Chain Support

- Expand to multi-chain deployment with cross-chain messaging.

---

## 6. **Next Steps**

1. **Integration and Testing:**
   - Integrate `VaultFactory`, `Vault`, and `GasStation`.
   - Write comprehensive unit and integration tests for all functionalities.
   - Perform security audits with a focus on:
     - Reentrancy
     - Token compatibility (e.g., tokens with custom `transfer()` logic)
     - Access control and authorization

2. **Governance Integration:**
   - Add governance for managing supported tokens, yield strategies, and fees.

3. **Deployment and Maintenance:**
   - Deploy on testnets for beta testing.
   - Monitor vaults with on-chain analytics tools.

---

## 7. **Summary**

This unified multi-vault design provides flexibility, scalability, and simplicity while maintaining robust security. It's suitable for building a multi-token deposit and withdrawal system that can grow with future token additions.
