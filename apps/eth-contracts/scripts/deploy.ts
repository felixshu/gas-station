import { ethers, upgrades } from "hardhat";
import type { ContractFactory, Contract } from "ethers";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import * as fs from "fs";
import * as path from "path";

// Helper function to deploy a regular contract
async function deployContract<T extends Contract>(
  name: string,
  factory: ContractFactory,
  deployer: HardhatEthersSigner,
  ...args: unknown[]
): Promise<T> {
  console.log(`\n📄 Deploying ${name}...`);
  const contract = await factory.connect(deployer).deploy(...args);
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log(`✅ ${name} deployed to: ${address}`);
  return contract as T;
}

// Helper function to deploy an upgradeable proxy contract
async function deployProxy<T extends Contract>(
  name: string,
  factory: ContractFactory,
  args: unknown[] = [],
  initializer = "initialize"
): Promise<T> {
  console.log(`\n📄 Deploying ${name} as upgradeable proxy...`);
  const contract = await upgrades.deployProxy(factory, args, {
    initializer,
    kind: "uups",
  });
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log(`✅ ${name} proxy deployed to: ${address}`);

  // Get implementation address
  const implAddress = await upgrades.erc1967.getImplementationAddress(address);
  console.log(`   Implementation address: ${implAddress}`);

  return contract as T;
}

// Helper function to save deployment information
async function saveDeployment(deployments: Record<string, string>, networkName: string) {
  const deploymentsDir = path.join(__dirname, "../deployments");

  // Create deployments directory if it doesn't exist
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const filePath = path.join(deploymentsDir, `${networkName}.json`);
  fs.writeFileSync(filePath, JSON.stringify(deployments, null, 2));

  console.log(`\n💾 Deployment information saved to: ${filePath}`);
}

async function main() {
  // Get the deployer account
  const [deployer] = await ethers.getSigners();
  console.log("\n🚀 Starting deployment process...");
  console.log(`📝 Deploying contracts with account: ${deployer.address}`);

  // Get network information
  const network = await ethers.provider.getNetwork();
  console.log(`🌐 Network: ${network.name} (chainId: ${network.chainId})`);

  const deployments: Record<string, string> = {
    network: network.name,
    chainId: network.chainId.toString(),
    deployer: deployer.address,
    deploymentDate: new Date().toISOString(),
  };

  try {
    // 1. Deploy TokenWhitelist
    console.log("\n🔄 Step 1: Deploying TokenWhitelist...");
    const TokenWhitelist = await ethers.getContractFactory("TokenWhitelist");
    const tokenWhitelist = await deployProxy("TokenWhitelist", TokenWhitelist);
    deployments.tokenWhitelist = await tokenWhitelist.getAddress();

    // 2. Deploy Vault Implementation
    console.log("\n🔄 Step 2: Deploying Vault Implementation...");
    const Vault = await ethers.getContractFactory("Vault");
    const vaultImplementation = await deployContract("Vault Implementation", Vault, deployer);
    deployments.vaultImplementation = await vaultImplementation.getAddress();

    // 3. Deploy VaultFactory
    console.log("\n🔄 Step 3: Deploying VaultFactory...");
    const VaultFactory = await ethers.getContractFactory("VaultFactory");
    const vaultFactory = await deployProxy("VaultFactory", VaultFactory, [
      await vaultImplementation.getAddress(),
      await tokenWhitelist.getAddress(),
    ]);
    deployments.vaultFactory = await vaultFactory.getAddress();

    // 4. Deploy Mock ERC20 tokens for testing (if on testnet)
    let defaultToken: string;
    let defaultPriceFeed: string;

    if (network.name === "mainnet") {
      // Use real addresses for mainnet
      console.log("\n🔄 Using mainnet token and price feed addresses");
      defaultToken = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // USDC on mainnet
      defaultPriceFeed = "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6"; // USDC/ETH price feed
    } else {
      // Deploy mocks for testnet
      console.log("\n🔄 Step 4: Deploying mock tokens and price feeds for testing...");

      // Deploy MockERC20 (USDC)
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const mockUSDC = await deployContract(
        "MockUSDC",
        MockERC20,
        deployer,
        "USD Coin",
        "USDC",
        6 // 6 decimals like real USDC
      );
      deployments.mockUSDC = await mockUSDC.getAddress();

      // Mint some tokens to the deployer
      const mintAmount = ethers.parseUnits("1000000", 6); // 1 million USDC
      console.log(`   Minting ${ethers.formatUnits(mintAmount, 6)} USDC to deployer...`);
      await mockUSDC.mint(deployer.address, mintAmount);

      // Deploy MockPriceFeed
      const MockPriceFeed = await ethers.getContractFactory("MockV3Aggregator");
      const mockUSDCPriceFeed = await deployContract(
        "MockUSDCPriceFeed",
        MockPriceFeed,
        deployer,
        8, // 8 decimals like Chainlink
        ethers.parseUnits("2000", 8) // $2000 per ETH
      );
      deployments.mockUSDCPriceFeed = await mockUSDCPriceFeed.getAddress();

      // Use the mock addresses
      defaultToken = await mockUSDC.getAddress();
      defaultPriceFeed = await mockUSDCPriceFeed.getAddress();

      // Whitelist the token immediately
      console.log("\n   Whitelisting token in TokenWhitelist...");
      await tokenWhitelist.addToken(defaultToken);
      console.log(`✅ Token ${defaultToken} whitelisted`);
    }

    // 5. Deploy GasStation
    console.log("\n🔄 Step 5: Deploying GasStation...");
    const GasStation = await ethers.getContractFactory("GasStation");

    // Configuration parameters - match test values more closely
    const minDepositAmount = ethers.parseUnits("10", 6); // 10 USDC minimum (like in tests)
    const maxDepositAmount = ethers.parseUnits("10000", 6); // 10,000 USDC maximum (like in tests)

    const gasStation = await deployProxy(
      "GasStation",
      GasStation,
      [
        {
          defaultToken,
          defaultPriceFeed,
          minDepositAmount,
          maxDepositAmount,
          vaultFactory: await vaultFactory.getAddress(),
        },
      ],
      "initialize"
    );
    deployments.gasStation = await gasStation.getAddress();

    // Explicitly set VaultFactory in GasStation (matching test setup)
    console.log("\n   Setting VaultFactory in GasStation...");
    await gasStation.setVaultFactory(await vaultFactory.getAddress());
    console.log("✅ VaultFactory set in GasStation");

    // 6. Create initial vault
    console.log("\n🔄 Step 6: Creating initial vault...");
    const gasStationAddress = await gasStation.getAddress();
    const createVaultTx = await vaultFactory.createVault(gasStationAddress);
    const createVaultReceipt = await createVaultTx.wait();

    // Find the VaultCreated event to get the vault address
    const vaultFactoryInterface = VaultFactory.interface;
    const vaultCreatedEvent = createVaultReceipt?.logs
      .map((log: any) => {
        try {
          return vaultFactoryInterface.parseLog({
            topics: log.topics as string[],
            data: log.data,
          });
        } catch (e) {
          return null;
        }
      })
      .find((event: any) => event?.name === "VaultCreated");

    if (vaultCreatedEvent && vaultCreatedEvent.args) {
      const vaultAddress = vaultCreatedEvent.args[1]; // The vault address is the second argument
      console.log(`✅ Initial vault created at: ${vaultAddress}`);
      deployments.initialVault = vaultAddress;

      // Get the vault address using the same method as in tests
      console.log("   Verifying vault address using getLastVaultByOwner...");
      const lastVaultAddress = await vaultFactory.getLastVaultByOwner(gasStationAddress);
      console.log(`   Last vault address: ${lastVaultAddress}`);

      if (lastVaultAddress.toLowerCase() !== vaultAddress.toLowerCase()) {
        console.warn("⚠️ Vault addresses from event and getLastVaultByOwner don't match!");
      }

      // Set the GasStation address in the vault
      console.log("   Setting GasStation address in the vault...");
      await gasStation.setVaultGasStation(vaultAddress, gasStationAddress);
      console.log("✅ GasStation address set in the vault");

      // Fund the vault with some ETH for testing
      if (network.name !== "mainnet") {
        console.log("   Funding vault with 10 ETH for testing...");
        await deployer.sendTransaction({
          to: vaultAddress,
          value: ethers.parseEther("10"),
        });
        console.log("✅ Vault funded with 10 ETH");
      }
    } else {
      console.log("⚠️ Could not find VaultCreated event in transaction logs");
    }

    // Print deployment summary
    console.log("\n📋 Deployment Summary:");
    console.log("====================");
    console.log(`TokenWhitelist: ${deployments.tokenWhitelist}`);
    console.log(`Vault Implementation: ${deployments.vaultImplementation}`);
    console.log(`VaultFactory: ${deployments.vaultFactory}`);
    console.log(`GasStation: ${deployments.gasStation}`);

    if (deployments.initialVault) {
      console.log(`Initial Vault: ${deployments.initialVault}`);
    }

    if (network.name !== "mainnet") {
      console.log(`MockUSDC: ${deployments.mockUSDC}`);
      console.log(`MockUSDCPriceFeed: ${deployments.mockUSDCPriceFeed}`);
    }

    // Save deployment information
    await saveDeployment(deployments, network.name);

    return deployments;
  } catch (error) {
    console.error("\n❌ Deployment failed:", error);
    throw error;
  }
}

// Execute the deployment
main()
  .then(() => {
    console.log("\n🎉 All deployments completed successfully");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  });
