# Makefile for Ethereum Smart Contract Development in Nx Monorepo
# This Makefile provides shortcuts for common development tasks

# Configuration
NX = npx nx
ETH_CONTRACTS_PROJECT = eth-contracts
NETWORK ?= localhost
GAS_REPORT ?= false
SOLHINT = npx solhint
PRETTIER = npx prettier
COVERAGE = npx hardhat coverage

# Default target
.PHONY: all
all: clean compile test

# Compile contracts
.PHONY: compile
compile:
	@echo "Compiling contracts..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):compile

# Run tests
.PHONY: test
test: compile
	@echo "Running tests..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):test

# Run specific test file
.PHONY: test-file
test-file:
	@echo "Running tests for $(FILE)..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):test --testFile=$(FILE)

# Run VaultFactory tests
.PHONY: test-vault-factory
test-vault-factory: compile
	@echo "Running VaultFactory tests..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):test --testFile=test/VaultFactory.test.ts

# Run TestVaultFactory tests
.PHONY: test-test-vault-factory
test-test-vault-factory: compile
	@echo "Running TestVaultFactory tests..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):test --testFile=test/TestVaultFactory.test.ts

# Run tests with gas reporting
.PHONY: test-gas
test-gas:
	@echo "Running tests with gas reporting..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):test --gasReport=true

# Generate test coverage report
.PHONY: coverage
coverage:
	@echo "Generating test coverage report..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):coverage

# Deploy contracts to network
.PHONY: deploy
deploy:
	@echo "Deploying contracts to $(NETWORK)..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):deploy --network=$(NETWORK)

# Start local node
.PHONY: node
node:
	@echo "Starting local Hardhat node..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):node

# Lint Solidity files
.PHONY: lint
lint:
	@echo "Linting Solidity files..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):lint

# Fix linting errors automatically
.PHONY: lint-fix
lint-fix:
	@echo "Fixing linting errors in Solidity files..."
	@$(SOLHINT) --fix 'contracts/**/*.sol'

# Format code
.PHONY: format
format:
	@echo "Formatting code..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):format

# Verify contracts on Etherscan
.PHONY: verify
verify:
	@echo "Verifying contract $(CONTRACT) on $(NETWORK)..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):verify --network=$(NETWORK) --contract=$(CONTRACT) --constructorArgs=$(ARGS)

# Clean build artifacts
.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	@$(NX) run $(ETH_CONTRACTS_PROJECT):clean
	@rm -rf coverage coverage.json typechain typechain-types

# Help command
.PHONY: help
help:
	@echo "Available commands:"
	@echo "  make all               - Clean, compile, and test contracts"
	@echo "  make compile           - Compile contracts"
	@echo "  make test              - Run all tests"
	@echo "  make test-file FILE=path/to/test.ts - Run specific test file"
	@echo "  make test-vault-factory - Run VaultFactory tests"
	@echo "  make test-test-vault-factory - Run TestVaultFactory tests"
	@echo "  make test-gas          - Run tests with gas reporting"
	@echo "  make coverage          - Generate test coverage report"
	@echo "  make deploy NETWORK=network_name - Deploy contracts to network"
	@echo "  make node              - Start local Hardhat node"
	@echo "  make lint              - Lint Solidity files"
	@echo "  make lint-fix          - Fix linting errors in Solidity files"
	@echo "  make format            - Format code"
	@echo "  make verify CONTRACT=address ARGS='arg1 arg2' NETWORK=network_name - Verify contract on Etherscan"
	@echo "  make clean             - Clean build artifacts"

# List available Nx targets for eth-contracts
.PHONY: list-targets
list-targets:
	@echo "Listing available Nx targets for eth-contracts project..."
	@$(NX) show project eth-contracts --target=all