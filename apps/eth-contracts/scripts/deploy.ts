import { ethers, upgrades } from "hardhat";
import type { ContractFactory, Contract, Wallet } from "ethers";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import * as fs from "fs";
import * as path from "path";
import "dotenv/config";

// Helper function to get deployer wallet from private key
async function getDeployer(): Promise<HardhatEthersSigner | Wallet> {
  // Check if private key is provided in environment variables
  const privateKey = process.env.PRIVATE_KEY;

  if (!privateKey) {
    console.warn(
      "\n⚠️ No PRIVATE_KEY found in environment variables. Using default hardhat account."
    );
    const [defaultSigner] = await ethers.getSigners();
    return defaultSigner;
  }

  try {
    // Create wallet from private key
    const provider = ethers.provider;
    const wallet = new ethers.Wallet(privateKey, provider);
    console.log(`\n🔑 Using wallet address: ${wallet.address}`);

    // Check wallet balance
    const balance = await provider.getBalance(wallet.address);
    console.log(`💰 Wallet balance: ${ethers.formatEther(balance)} ETH`);

    if (balance === BigInt(0)) {
      console.warn("⚠️ Warning: Deployer wallet has zero balance!");
    }

    return wallet;
  } catch (error) {
    console.error("\n❌ Error creating wallet from private key:", error);
    console.warn("⚠️ Falling back to default hardhat account");
    const [defaultSigner] = await ethers.getSigners();
    return defaultSigner;
  }
}

// Helper function to get buyer wallet from private key
async function getBuyer(): Promise<HardhatEthersSigner | Wallet | null> {
  // Check if buyer private key is provided in environment variables
  const buyerPrivateKey = process.env.BUYER_PRIVATE_KEY;

  if (!buyerPrivateKey) {
    console.warn(
      "\n⚠️ No BUYER_PRIVATE_KEY found in environment variables. Buyer setup will be skipped."
    );
    return null;
  }

  try {
    // Create wallet from private key
    const provider = ethers.provider;
    const wallet = new ethers.Wallet(buyerPrivateKey, provider);
    console.log(`\n👤 Using buyer wallet address: ${wallet.address}`);

    // Check wallet balance
    const balance = await provider.getBalance(wallet.address);
    console.log(`💰 Buyer wallet balance: ${ethers.formatEther(balance)} ETH`);

    if (balance === BigInt(0)) {
      console.warn("⚠️ Warning: Buyer wallet has zero balance!");
    }

    return wallet;
  } catch (error) {
    console.error("\n❌ Error creating buyer wallet from private key:", error);
    return null;
  }
}

// Helper function to deploy a regular contract
async function deployContract<T extends Contract>(
  name: string,
  factory: ContractFactory,
  deployer: HardhatEthersSigner | Wallet,
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

// Helper function to check if we're on a testnet
function isTestnet(networkName: string): boolean {
  const testnets = ["sepolia", "goerli", "hardhat", "localhost", "development"];
  return testnets.includes(networkName.toLowerCase());
}

async function main() {
  // Get the deployer account using private key
  const deployer = await getDeployer();
  console.log("\n🚀 Starting deployment process...");
  console.log(`📝 Deploying contracts with account: ${deployer.address}`);

  // Get network information
  const network = await ethers.provider.getNetwork();
  console.log(`🌐 Network: ${network.name} (chainId: ${network.chainId})`);

  // Check if we're on a testnet
  const onTestnet = isTestnet(network.name);
  console.log(`${onTestnet ? "🧪 Testnet detected" : "🌐 Mainnet detected"}`);

  // Initialize deployments record
  const deployments: Record<string, string> = {
    network: network.name,
    chainId: network.chainId.toString(),
    deployer: deployer.address,
    deploymentDate: new Date().toISOString(),
  };

  // Get the buyer account if available (only relevant for testnets)
  let buyer = null;
  if (onTestnet) {
    buyer = await getBuyer();
    if (buyer) {
      console.log(`👤 Buyer account set up: ${buyer.address}`);
      deployments.buyer = buyer.address;
    }
  }

  try {
    // 1. Deploy TokenWhitelist
    console.log("\n🔄 Step 1: Deploying TokenWhitelist...");
    const TokenWhitelist = await ethers.getContractFactory("TokenWhitelist", deployer);
    const tokenWhitelist = await deployProxy("TokenWhitelist", TokenWhitelist);
    deployments.tokenWhitelist = await tokenWhitelist.getAddress();

    // 2. Deploy Vault Implementation
    console.log("\n🔄 Step 2: Deploying Vault Implementation...");
    const Vault = await ethers.getContractFactory("Vault", deployer);
    const vaultImplementation = await deployContract("Vault Implementation", Vault, deployer);
    deployments.vaultImplementation = await vaultImplementation.getAddress();

    // 3. Deploy VaultFactory
    console.log("\n🔄 Step 3: Deploying VaultFactory...");
    const VaultFactory = await ethers.getContractFactory("VaultFactory", deployer);
    const vaultFactory = await deployProxy("VaultFactory", VaultFactory, [
      await vaultImplementation.getAddress(),
      await tokenWhitelist.getAddress(),
    ]);
    deployments.vaultFactory = await vaultFactory.getAddress();

    // 4. Set up tokens and price feeds
    let defaultToken: string;
    let defaultPriceFeed: string;
    let DAIAddress: string | undefined;
    let DAIPriceFeed: string | undefined;

    if (!onTestnet) {
      // Mainnet configuration
      console.log("\n🔄 Step 4: Using mainnet token and price feed addresses");

      // USDC on mainnet
      defaultToken = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // USDC on mainnet, decimal 6
      defaultPriceFeed = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"; // ETH/USD price feed

      // DAI on mainnet
      DAIAddress = "0x6B175474E89094C44Da98b954EedeAC495271d0F"; // DAI on mainnet
      DAIPriceFeed = "0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9"; // DAI/USD price feed

      deployments.USDC = defaultToken;
      deployments.USDCPriceFeed = defaultPriceFeed;
      deployments.DAI = DAIAddress;
      deployments.DAIPriceFeed = DAIPriceFeed;

      // Whitelist the tokens
      console.log("\n   Whitelisting USDC in TokenWhitelist...");
      await tokenWhitelist.addToken(defaultToken);
      console.log(`✅ USDC token whitelisted`);

      console.log("\n   Whitelisting DAI in TokenWhitelist...");
      await tokenWhitelist.addToken(DAIAddress);
      console.log(`✅ DAI token whitelisted`);
    } else {
      // Testnet configuration - deploy mock tokens
      console.log("\n🔄 Step 4: Deploying mock tokens and price feeds for testing...");

      // Deploy MockERC20 (USDC)
      const MockERC20 = await ethers.getContractFactory("MockERC20-1", deployer);
      const mockUSDC = await deployContract(
        "MockUSDC",
        MockERC20,
        deployer,
        "USD Coin",
        "USDC",
        6 // 6 decimals like real USDC
      );
      deployments.mockUSDC = await mockUSDC.getAddress();

      // Deploy MockERC20 (DAI)
      const MockERC20DAI = await ethers.getContractFactory("MockERC20-2", deployer);
      const mockDAI = await deployContract(
        "MockDAI",
        MockERC20DAI,
        deployer,
        "Dai Stablecoin",
        "DAI",
        18 // 18 decimals like real DAI
      );
      deployments.mockDAI = await mockDAI.getAddress();

      // Mint some tokens to the deployer
      console.log("\n   Minting tokens to deployer...");
      await mockUSDC.mint(deployer.address, ethers.parseUnits("10000000", 6));
      await mockDAI.mint(deployer.address, ethers.parseUnits("10000000", 18));
      console.log("✅ Tokens minted to deployer");

      // Mint tokens to the buyer if available
      if (buyer) {
        console.log("\n   Minting tokens to buyer...");
        const buyerUsdcAmount = ethers.parseUnits("1000000", 6); // 1 million USDC
        const buyerDaiAmount = ethers.parseUnits("1000000", 18); // 1 million DAI

        await mockUSDC.mint(buyer.address, buyerUsdcAmount);
        await mockDAI.mint(buyer.address, buyerDaiAmount);

        console.log(`✅ Minted ${ethers.formatUnits(buyerUsdcAmount, 6)} USDC to buyer`);
        console.log(`✅ Minted ${ethers.formatUnits(buyerDaiAmount, 18)} DAI to buyer`);
      }

      // Price feed for ETH/USD on Sepolia
      deployments.mockUSDCPriceFeed = "0x694AA1769357215DE4FAC081bf1f309aDC325306";
      // Price feed for DAI/ETH on Sepolia
      deployments.mockDAIPriceFeed = "0x14866185B1962B63C3Ea9E03Bc1da838bab34C19";

      // Use the mock addresses
      defaultToken = deployments.mockUSDC;
      defaultPriceFeed = deployments.mockUSDCPriceFeed;

      DAIAddress = deployments.mockDAI;
      DAIPriceFeed = deployments.mockDAIPriceFeed;

      // Whitelist the tokens
      console.log("\n   Whitelisting tokens in TokenWhitelist...");
      await tokenWhitelist.addToken(defaultToken);
      await tokenWhitelist.addToken(DAIAddress);
      console.log(`✅ Tokens whitelisted`);
    }

    // 5. Deploy GasStation
    console.log("\n🔄 Step 5: Deploying GasStation...");
    const GasStation = await ethers.getContractFactory("GasStation", deployer);

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

    // Add the DAI token to the Gas Station with its price feed (TESTNET ONLY)
    if (onTestnet) {
      if (DAIAddress && DAIPriceFeed) {
        console.log("\n   Adding DAI token to Gas Station with its price feed...");
        await gasStation.addPaymentToken(DAIAddress, DAIPriceFeed);
        console.log("✅ DAI token added to Gas Station with its price feed");
      }
    }

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

      // Fund the vault with some ETH for testing (only on testnet)
      if (onTestnet) {
        console.log("   Funding vault with 3 ETH for testing...");
        await deployer.sendTransaction({
          to: vaultAddress,
          value: ethers.parseEther("3"),
        });
        console.log("✅ Vault funded with 3 ETH");
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

    if (onTestnet) {
      console.log(`MockUSDC: ${deployments.mockUSDC}`);
      console.log(`MockDAI: ${deployments.mockDAI}`);
      console.log(`MockUSDCPriceFeed: ${deployments.mockUSDCPriceFeed}`);
      console.log(`MockDAIPriceFeed: ${deployments.mockDAIPriceFeed}`);

      if (buyer) {
        console.log(`Buyer Address: ${buyer.address}`);
      }
    } else {
      console.log(`USDC: ${deployments.USDC}`);
      console.log(`USDC Price Feed: ${deployments.USDCPriceFeed}`);
      console.log(`DAI: ${deployments.DAI}`);
      console.log(`DAI Price Feed: ${deployments.DAIPriceFeed}`);
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
