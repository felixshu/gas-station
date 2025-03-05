import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import type { Contract } from "ethers";
import type {
  GasStation,
  VaultFactory,
  Vault,
  MockERC20,
  MockPriceFeed,
  TokenWhitelist,
} from "../typechain-types";

describe("GasStation Fee Module", function () {
  let gasStation: GasStation & Contract;
  let vaultFactory: VaultFactory & Contract;
  let tokenWhitelist: TokenWhitelist & Contract;
  let mockUSDC: MockERC20 & Contract;
  let mockPriceFeed: MockPriceFeed & Contract;
  let owner: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let otherUser: HardhatEthersSigner;

  // Constants
  const ETH_PRICE = ethers.parseUnits("2000", 8); // $2000 per ETH with 8 decimals
  const MIN_DEPOSIT = ethers.parseUnits("10", 6); // 10 USDC
  const MAX_DEPOSIT = ethers.parseUnits("10000", 6); // 10,000 USDC
  const INITIAL_SUPPLY = ethers.parseUnits("1000000", 6); // 1,000,000 USDC

  async function deployFixture() {
    [owner, user, otherUser] = await ethers.getSigners();

    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    mockUSDC = (await MockERC20Factory.deploy("USD Coin", "USDC", 6)) as MockERC20 & Contract;
    await mockUSDC.mint(await user.getAddress(), INITIAL_SUPPLY);

    const MockPriceFeedFactory = await ethers.getContractFactory("MockPriceFeed");
    mockPriceFeed = (await MockPriceFeedFactory.deploy()) as MockPriceFeed & Contract;
    await mockPriceFeed.setPrice(ETH_PRICE);

    // Deploy Vault implementation
    const VaultFactory = await ethers.getContractFactory("Vault");
    const vaultImplementation = (await VaultFactory.deploy()) as Vault & Contract;
    await vaultImplementation.waitForDeployment();

    // Deploy TokenWhitelist
    const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");
    tokenWhitelist = (await upgrades.deployProxy(TokenWhitelistFactory, [], {
      initializer: "initialize",
      kind: "uups",
    })) as TokenWhitelist & Contract;
    await tokenWhitelist.waitForDeployment();

    // Deploy VaultFactory
    const VaultFactoryFactory = await ethers.getContractFactory("VaultFactory");
    vaultFactory = (await upgrades.deployProxy(
      VaultFactoryFactory,
      [await vaultImplementation.getAddress(), await tokenWhitelist.getAddress()],
      {
        initializer: "initialize",
        kind: "uups",
      }
    )) as VaultFactory & Contract;
    await vaultFactory.waitForDeployment();

    // Deploy GasStation
    const GasStationFactory = await ethers.getContractFactory("GasStation");
    gasStation = (await upgrades.deployProxy(
      GasStationFactory,
      [
        {
          defaultToken: await mockUSDC.getAddress(),
          defaultPriceFeed: await mockPriceFeed.getAddress(),
          minDepositAmount: MIN_DEPOSIT,
          maxDepositAmount: MAX_DEPOSIT,
          vaultFactory: await vaultFactory.getAddress(),
        },
      ],
      {
        initializer: "initialize",
        kind: "uups",
      }
    )) as GasStation & Contract;
    await gasStation.waitForDeployment();

    // Add USDC as a payment token
    await gasStation.addPaymentToken(await mockUSDC.getAddress(), await mockPriceFeed.getAddress());

    return {
      gasStation,
      vaultFactory,
      tokenWhitelist,
      mockUSDC,
      mockPriceFeed,
      owner,
      user,
      otherUser,
    };
  }

  describe("Fee Configuration", function () {
    it("should initialize with default fee configuration", async function () {
      const { gasStation } = await loadFixture(deployFixture);

      const feeConfig = await gasStation.feeConfig();
      expect(feeConfig.maxFeeBps).to.equal(50); // 0.5%
      expect(feeConfig.feeCollector).to.equal(await owner.getAddress());
      expect(feeConfig.feeEnabled).to.be.true;
    });

    it("should allow owner to update max fee", async function () {
      const { gasStation, owner } = await loadFixture(deployFixture);

      const tx = await gasStation.connect(owner).setMaxFeeBps(100); // 1%
      await expect(tx).to.emit(gasStation, "MaxFeeUpdated").withArgs(100);

      const feeConfig = await gasStation.feeConfig();
      expect(feeConfig.maxFeeBps).to.equal(100);
    });

    it("should allow owner to update fee collector", async function () {
      const { gasStation, owner, otherUser } = await loadFixture(deployFixture);

      const otherUserAddress = await otherUser.getAddress();
      const tx = await gasStation.connect(owner).setFeeCollector(otherUserAddress);
      await expect(tx).to.emit(gasStation, "FeeCollectorUpdated").withArgs(otherUserAddress);

      const feeConfig = await gasStation.feeConfig();
      expect(feeConfig.feeCollector).to.equal(otherUserAddress);
    });

    it("should allow owner to toggle fee collection", async function () {
      const { gasStation, owner } = await loadFixture(deployFixture);

      // Disable fees
      let tx = await gasStation.connect(owner).toggleFeeCollection(false);
      await expect(tx).to.emit(gasStation, "FeeCollectionToggled").withArgs(false);

      let feeConfig = await gasStation.feeConfig();
      expect(feeConfig.feeEnabled).to.be.false;

      // Enable fees again
      tx = await gasStation.connect(owner).toggleFeeCollection(true);
      await expect(tx).to.emit(gasStation, "FeeCollectionToggled").withArgs(true);

      feeConfig = await gasStation.feeConfig();
      expect(feeConfig.feeEnabled).to.be.true;
    });

    it("should not allow non-owner to modify fee configuration", async function () {
      const { gasStation, user } = await loadFixture(deployFixture);

      await expect(gasStation.connect(user).setMaxFeeBps(100))
        .to.be.revertedWithCustomError(gasStation, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());

      await expect(gasStation.connect(user).setFeeCollector(await user.getAddress()))
        .to.be.revertedWithCustomError(gasStation, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());

      await expect(gasStation.connect(user).toggleFeeCollection(false))
        .to.be.revertedWithCustomError(gasStation, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());
    });
  });

  describe("Fee Tiers", function () {
    it("should initialize with default fee tiers", async function () {
      const { gasStation, mockUSDC } = await loadFixture(deployFixture);

      const usdcAddress = await mockUSDC.getAddress();
      const tiers = await gasStation.getFeeTiers(usdcAddress);

      expect(tiers.length).to.equal(3);

      // Tier 1: 0-100 USDC → 0.5% fee
      expect(tiers[0].minAmount).to.equal(0);
      expect(tiers[0].feeBps).to.equal(50);
      expect(tiers[0].isActive).to.be.true;

      // Tier 2: 100-500 USDC → 0.4% fee
      expect(tiers[1].minAmount).to.equal(ethers.parseUnits("100", 6));
      expect(tiers[1].feeBps).to.equal(40);
      expect(tiers[1].isActive).to.be.true;

      // Tier 3: 500+ USDC → 0.3% fee
      expect(tiers[2].minAmount).to.equal(ethers.parseUnits("500", 6));
      expect(tiers[2].feeBps).to.equal(30);
      expect(tiers[2].isActive).to.be.true;
    });

    it("should allow owner to add a new fee tier", async function () {
      const { gasStation, owner, mockUSDC } = await loadFixture(deployFixture);

      const usdcAddress = await mockUSDC.getAddress();
      const minAmount = ethers.parseUnits("1000", 6); // 1000 USDC
      const feeBps = 20; // 0.2%

      const tx = await gasStation.connect(owner).addFeeTier(usdcAddress, minAmount, feeBps);

      await expect(tx).to.emit(gasStation, "FeeTierAdded").withArgs(usdcAddress, minAmount, feeBps);

      const tiers = await gasStation.getFeeTiers(usdcAddress);
      expect(tiers.length).to.equal(4);

      // New tier: 1000+ USDC → 0.2% fee
      expect(tiers[3].minAmount).to.equal(minAmount);
      expect(tiers[3].feeBps).to.equal(feeBps);
      expect(tiers[3].isActive).to.be.true;
    });

    it("should allow owner to update a fee tier", async function () {
      const { gasStation, owner, mockUSDC } = await loadFixture(deployFixture);

      const usdcAddress = await mockUSDC.getAddress();
      const tierIndex = 1; // 100-500 USDC tier
      const newMinAmount = ethers.parseUnits("200", 6); // 200 USDC
      const newFeeBps = 35; // 0.35%

      const tx = await gasStation
        .connect(owner)
        .updateFeeTier(usdcAddress, tierIndex, newMinAmount, newFeeBps);

      await expect(tx)
        .to.emit(gasStation, "FeeTierUpdated")
        .withArgs(usdcAddress, tierIndex, newMinAmount, newFeeBps);

      const tiers = await gasStation.getFeeTiers(usdcAddress);

      // Updated tier: 200+ USDC → 0.35% fee
      expect(tiers[tierIndex].minAmount).to.equal(newMinAmount);
      expect(tiers[tierIndex].feeBps).to.equal(newFeeBps);
      expect(tiers[tierIndex].isActive).to.be.true;
    });

    it("should allow owner to remove a fee tier", async function () {
      const { gasStation, owner, mockUSDC } = await loadFixture(deployFixture);

      const usdcAddress = await mockUSDC.getAddress();
      const tierIndex = 1; // 100-500 USDC tier

      const tx = await gasStation.connect(owner).removeFeeTier(usdcAddress, tierIndex);

      await expect(tx).to.emit(gasStation, "FeeTierRemoved").withArgs(usdcAddress, tierIndex);

      const tiers = await gasStation.getFeeTiers(usdcAddress);
      expect(tiers.length).to.equal(2);

      // Tier 1: 0-100 USDC → 0.5% fee
      expect(tiers[0].minAmount).to.equal(0);
      expect(tiers[0].feeBps).to.equal(50);
      expect(tiers[0].isActive).to.be.true;

      // Tier 2: 500+ USDC → 0.3% fee (previously tier 3)
      expect(tiers[1].minAmount).to.equal(ethers.parseUnits("500", 6));
      expect(tiers[1].feeBps).to.equal(30);
      expect(tiers[1].isActive).to.be.true;
    });

    it("should not allow non-owner to modify fee tiers", async function () {
      const { gasStation, user, mockUSDC } = await loadFixture(deployFixture);

      const usdcAddress = await mockUSDC.getAddress();

      await expect(gasStation.connect(user).addFeeTier(usdcAddress, 0, 10))
        .to.be.revertedWithCustomError(gasStation, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());

      await expect(gasStation.connect(user).updateFeeTier(usdcAddress, 0, 0, 10))
        .to.be.revertedWithCustomError(gasStation, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());

      await expect(gasStation.connect(user).removeFeeTier(usdcAddress, 0))
        .to.be.revertedWithCustomError(gasStation, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());
    });
  });

  describe("Fee Calculation", function () {
    it("should calculate fee based on the correct tier", async function () {
      const { gasStation, mockUSDC } = await loadFixture(deployFixture);

      const usdcAddress = await mockUSDC.getAddress();

      // Tier 1: 0-100 USDC → 0.5% fee
      let amount = ethers.parseUnits("50", 6); // 50 USDC
      let expectedFee = (amount * BigInt(50)) / BigInt(10000); // 0.5% fee
      let calculatedFee = await gasStation.calculateFee(usdcAddress, amount);
      expect(calculatedFee).to.equal(expectedFee);

      // Tier 2: 100-500 USDC → 0.4% fee
      amount = ethers.parseUnits("200", 6); // 200 USDC
      expectedFee = (amount * BigInt(40)) / BigInt(10000); // 0.4% fee
      calculatedFee = await gasStation.calculateFee(usdcAddress, amount);
      expect(calculatedFee).to.equal(expectedFee);

      // Tier 3: 500+ USDC → 0.3% fee
      amount = ethers.parseUnits("1000", 6); // 1000 USDC
      expectedFee = (amount * BigInt(30)) / BigInt(10000); // 0.3% fee
      calculatedFee = await gasStation.calculateFee(usdcAddress, amount);
      expect(calculatedFee).to.equal(expectedFee);
    });

    it("should return 0 fee when fee collection is disabled", async function () {
      const { gasStation, owner, mockUSDC } = await loadFixture(deployFixture);

      const usdcAddress = await mockUSDC.getAddress();
      const amount = ethers.parseUnits("1000", 6); // 1000 USDC

      // Disable fees
      await gasStation.connect(owner).toggleFeeCollection(false);

      const calculatedFee = await gasStation.calculateFee(usdcAddress, amount);
      expect(calculatedFee).to.equal(0);
    });

    it("should handle new tokens with default fee tiers", async function () {
      const { gasStation, owner, mockPriceFeed } = await loadFixture(deployFixture);

      // Deploy a new token
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20Factory.deploy("New Token", "NEW", 18);
      const newTokenAddress = await newToken.getAddress();

      // Add the new token as a payment token
      await gasStation
        .connect(owner)
        .addPaymentToken(newTokenAddress, await mockPriceFeed.getAddress());

      // Add default fee tiers for the new token
      await gasStation.connect(owner).addFeeTier(newTokenAddress, 0, 50); // 0.5% for 0+
      await gasStation.connect(owner).addFeeTier(
        newTokenAddress,
        ethers.parseUnits("100", 18), // 100 tokens
        40 // 0.4%
      );
      await gasStation.connect(owner).addFeeTier(
        newTokenAddress,
        ethers.parseUnits("500", 18), // 500 tokens
        30 // 0.3%
      );

      // Check that the fee tiers were created
      const tiers = await gasStation.getFeeTiers(newTokenAddress);
      expect(tiers.length).to.equal(3);

      // Calculate fee for the new token
      const amount = ethers.parseUnits("50", 18); // 50 tokens
      const expectedFee = (amount * BigInt(50)) / BigInt(10000); // 0.5% fee
      const calculatedFee = await gasStation.calculateFee(newTokenAddress, amount);
      expect(calculatedFee).to.equal(expectedFee);
    });
  });
});
