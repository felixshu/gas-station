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

    // Add USDC to the TokenWhitelist
    await tokenWhitelist.addToken(await mockUSDC.getAddress());

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

    it("should correctly calculate amount after fee deduction", async function () {
      const fixture = await loadFixture(deployFixture);
      gasStation = fixture.gasStation;
      mockUSDC = fixture.mockUSDC;
      owner = fixture.owner;

      const usdcAddress = await mockUSDC.getAddress();

      // Test with different amounts across fee tiers
      const amounts = [
        ethers.parseUnits("50", 6), // Tier 1: 0.5% fee
        ethers.parseUnits("300", 6), // Tier 2: 0.4% fee
        ethers.parseUnits("1000", 6), // Tier 3: 0.3% fee
      ];

      for (const amount of amounts) {
        const expectedFee = await gasStation.calculateFee(usdcAddress, amount);
        const expectedAmountAfterFee = amount - expectedFee;

        const actualAmountAfterFee = await gasStation.calculateAmountAfterFee(usdcAddress, amount);

        expect(actualAmountAfterFee).to.equal(expectedAmountAfterFee);
      }

      // Test when fee collection is disabled
      await gasStation.toggleFeeCollection(false);
      const amount = ethers.parseUnits("1000", 6);
      const amountAfterFee = await gasStation.calculateAmountAfterFee(usdcAddress, amount);
      expect(amountAfterFee).to.equal(amount); // No fee deduction

      // Re-enable fee collection for other tests
      await gasStation.toggleFeeCollection(true);
    });
  });

  describe("Fee Collection and Withdrawal", function () {
    beforeEach(async function () {
      const fixture = await loadFixture(deployFixture);
      gasStation = fixture.gasStation;
      mockUSDC = fixture.mockUSDC;
      owner = fixture.owner;
      user = fixture.user;
      otherUser = fixture.otherUser;

      // Create a vault for GasStation to use for exchanges
      const vaultFactory = fixture.vaultFactory;
      const gasStationAddress = await gasStation.getAddress();

      // Create a vault for the GasStation
      await vaultFactory.createVault(gasStationAddress);
      const vaultAddress = await vaultFactory.getLastVaultByOwner(gasStationAddress);

      // Set the gasStation address in the Vault contract
      await gasStation.setVaultGasStation(vaultAddress, gasStationAddress);

      // Fund the vault with ETH
      await owner.sendTransaction({
        to: vaultAddress,
        value: ethers.parseEther("10"),
      });
    });

    it("should collect fees during exchange", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const amount = ethers.parseUnits("1000", 6); // 1000 USDC
      const expectedFee = (amount * BigInt(30)) / BigInt(10000); // 0.3% for Tier 3

      // Initial fee balance should be 0
      expect(await gasStation.totalFeesCollected(usdcAddress)).to.equal(0);

      // Execute exchange
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount);
      const tx = await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount,
        destination: await user.getAddress(),
      });

      // Check fee collection event
      await expect(tx).to.emit(gasStation, "FeesCollected").withArgs(usdcAddress, expectedFee);

      // Check that fees were collected
      expect(await gasStation.totalFeesCollected(usdcAddress)).to.equal(expectedFee);
    });

    it("should track user volume", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const amount = ethers.parseUnits("500", 6); // 500 USDC

      // Initial volume should be 0
      expect(await gasStation.getUserVolume(await user.getAddress(), usdcAddress)).to.equal(0);

      // Execute exchange
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount);
      await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount,
        destination: await user.getAddress(),
      });

      // Check that volume was updated
      const newVolume = await gasStation.getUserVolume(await user.getAddress(), usdcAddress);
      expect(newVolume).to.equal(amount);

      // Execute another exchange
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount);
      await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount,
        destination: await user.getAddress(),
      });

      // Check that volume was accumulated
      const finalVolume = await gasStation.getUserVolume(await user.getAddress(), usdcAddress);
      expect(finalVolume).to.equal(amount * BigInt(2));
    });

    it("should allow owner to withdraw collected fees", async function () {
      const usdcAddress = await mockUSDC.getAddress();

      // First, ensure we have some fees to withdraw by making an exchange
      const amount = ethers.parseUnits("1000", 6); // 1000 USDC
      await mockUSDC.mint(await user.getAddress(), amount);
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount);
      await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount,
        destination: await user.getAddress(),
      });

      // Get the fee amount that was collected
      const feesCollected = await gasStation.totalFeesCollected(usdcAddress);
      expect(feesCollected).to.be.gt(0);

      // Mint the fee amount directly to the GasStation contract to simulate collected fees
      await mockUSDC.mint(await gasStation.getAddress(), feesCollected);

      const feeCollector = (await gasStation.feeConfig()).feeCollector;

      // Get initial balance of fee collector
      const initialBalance = await mockUSDC.balanceOf(feeCollector);

      // Withdraw fees
      const tx = await gasStation.connect(owner).withdrawFees(usdcAddress);

      // Check withdrawal event
      await expect(tx).to.emit(gasStation, "FeesWithdrawn").withArgs(usdcAddress, feesCollected);

      // Check that fees were transferred to fee collector
      const newBalance = await mockUSDC.balanceOf(feeCollector);
      expect(newBalance).to.equal(initialBalance + feesCollected);

      // Check that fees collected is reset to 0
      expect(await gasStation.totalFeesCollected(usdcAddress)).to.equal(0);
    });

    it("should revert when withdrawing fees for unsupported token", async function () {
      // Create a new token that is not supported
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const unsupportedToken = await MockERC20Factory.deploy("Unsupported Token", "UNSUP", 18);
      const unsupportedTokenAddress = await unsupportedToken.getAddress();

      // Attempt to withdraw fees for unsupported token
      await expect(gasStation.connect(owner).withdrawFees(unsupportedTokenAddress))
        .to.be.revertedWithCustomError(gasStation, "TokenNotSupported")
        .withArgs(unsupportedTokenAddress);
    });

    it("should revert when withdrawing zero fees", async function () {
      const usdcAddress = await mockUSDC.getAddress();

      // No fees have been collected yet
      expect(await gasStation.totalFeesCollected(usdcAddress)).to.equal(0);

      // Attempt to withdraw zero fees
      await expect(
        gasStation.connect(owner).withdrawFees(usdcAddress)
      ).to.be.revertedWithCustomError(gasStation, "ZeroAmount");
    });

    it("should handle fee withdrawal security when fee collector changes", async function () {
      const usdcAddress = await mockUSDC.getAddress();

      // Collect some fees
      const amount = ethers.parseUnits("1000", 6); // 1000 USDC
      await mockUSDC.mint(await user.getAddress(), amount);
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount);
      await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount,
        destination: await user.getAddress(),
      });

      // Ensure we have some fees to withdraw
      const feesCollected = await gasStation.totalFeesCollected(usdcAddress);
      expect(feesCollected).to.be.gt(0);

      // Mint the fee amount directly to the GasStation contract to simulate collected fees
      await mockUSDC.mint(await gasStation.getAddress(), feesCollected);

      // Change fee collector to a different address
      const newFeeCollector = await otherUser.getAddress();
      await gasStation.connect(owner).setFeeCollector(newFeeCollector);

      // Withdraw fees
      await gasStation.connect(owner).withdrawFees(usdcAddress);

      // Check that fees were sent to the new fee collector
      const newFeeCollectorBalance = await mockUSDC.balanceOf(newFeeCollector);
      expect(newFeeCollectorBalance).to.equal(feesCollected);
    });
  });

  describe("Fee Integration with Exchange", function () {
    beforeEach(async function () {
      const fixture = await loadFixture(deployFixture);
      gasStation = fixture.gasStation;
      mockUSDC = fixture.mockUSDC;
      mockPriceFeed = fixture.mockPriceFeed;
      owner = fixture.owner;
      user = fixture.user;
      otherUser = fixture.otherUser;

      // Create a vault for GasStation to use for exchanges
      const vaultFactory = fixture.vaultFactory;
      const gasStationAddress = await gasStation.getAddress();

      // Create a vault for the GasStation
      await vaultFactory.createVault(gasStationAddress);
      const vaultAddress = await vaultFactory.getLastVaultByOwner(gasStationAddress);

      // Set the gasStation address in the Vault contract
      await gasStation.setVaultGasStation(vaultAddress, gasStationAddress);

      // Fund the vault with ETH
      await owner.sendTransaction({
        to: vaultAddress,
        value: ethers.parseEther("10"),
      });
    });

    it("should correctly handle fees during exchange", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const amount = ethers.parseUnits("1000", 6); // 1000 USDC
      const fee = (amount * BigInt(30)) / BigInt(10000); // 0.3% fee for Tier 3
      const amountAfterFee = amount - fee;

      // Calculate expected ETH amount
      const expectedEthAmount = await gasStation.calculateEthAmount(usdcAddress, amount);

      // Get initial balances
      const userBalanceBefore = await ethers.provider.getBalance(await user.getAddress());
      const initialFeeCollected = await gasStation.totalFeesCollected(usdcAddress);

      // Execute exchange
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount);
      const tx = await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount,
        destination: await user.getAddress(),
      });

      // Check fee collection event
      await expect(tx).to.emit(gasStation, "FeesCollected").withArgs(usdcAddress, fee);

      // Check deposit processed event with correct ETH amount
      await expect(tx)
        .to.emit(gasStation, "DepositProcessed")
        .withArgs(
          await user.getAddress(),
          usdcAddress,
          amount,
          expectedEthAmount,
          await user.getAddress()
        );

      // Verify the user's balance decreased by the full amount
      const userBalanceAfter = await ethers.provider.getBalance(await user.getAddress());
      const receipt = await tx.wait();
      if (!receipt) throw new Error("Transaction receipt is null");
      const gasUsed = receipt.gasUsed * receipt.gasPrice;
      const actualEthReceived = userBalanceAfter + gasUsed - userBalanceBefore;

      // Verify the ETH amount received matches the expected ETH amount
      expect(actualEthReceived).to.be.closeTo(
        expectedEthAmount,
        ethers.parseEther("0.01") // Allow for small rounding differences
      );

      // Verify the fee was collected correctly
      const finalFeeCollected = await gasStation.totalFeesCollected(usdcAddress);
      expect(finalFeeCollected - initialFeeCollected).to.equal(fee);

      // Verify the amount after fee is correct by checking the difference between
      // what the user sent and what was collected as fees
      expect(amount - fee).to.equal(amountAfterFee);
    });

    it("should not collect fees when fee collection is disabled", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const amount = ethers.parseUnits("1000", 6); // 1000 USDC

      // Disable fee collection
      await gasStation.connect(owner).toggleFeeCollection(false);

      // Initial fee balance
      const initialFeeBalance = await gasStation.totalFeesCollected(usdcAddress);

      // Execute exchange
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount);
      const tx = await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount,
        destination: await user.getAddress(),
      });

      // Check that no FeesCollected event was emitted
      await expect(tx).to.not.emit(gasStation, "FeesCollected");

      // Check that fees were not collected
      expect(await gasStation.totalFeesCollected(usdcAddress)).to.equal(initialFeeBalance);
    });

    it("should apply different fee tiers based on transaction amount", async function () {
      const usdcAddress = await mockUSDC.getAddress();

      // Test with amount in Tier 1: 0-100 USDC → 0.5% fee
      const amount1 = ethers.parseUnits("50", 6); // 50 USDC
      const expectedFee1 = (amount1 * BigInt(50)) / BigInt(10000); // 0.5%

      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount1);
      const tx1 = await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount1,
        destination: await user.getAddress(),
      });

      await expect(tx1).to.emit(gasStation, "FeesCollected").withArgs(usdcAddress, expectedFee1);

      // Test with amount in Tier 2: 100-500 USDC → 0.4% fee
      const amount2 = ethers.parseUnits("200", 6); // 200 USDC
      const expectedFee2 = (amount2 * BigInt(40)) / BigInt(10000); // 0.4%

      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount2);
      const tx2 = await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount2,
        destination: await user.getAddress(),
      });

      await expect(tx2).to.emit(gasStation, "FeesCollected").withArgs(usdcAddress, expectedFee2);

      // Test with amount in Tier 3: 500+ USDC → 0.3% fee
      const amount3 = ethers.parseUnits("600", 6); // 600 USDC
      const expectedFee3 = (amount3 * BigInt(30)) / BigInt(10000); // 0.3%

      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount3);
      const tx3 = await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount3,
        destination: await user.getAddress(),
      });

      await expect(tx3).to.emit(gasStation, "FeesCollected").withArgs(usdcAddress, expectedFee3);
    });

    it("should handle multiple exchanges with accumulating fees", async function () {
      const usdcAddress = await mockUSDC.getAddress();
      const amount = ethers.parseUnits("500", 6); // 500 USDC
      const fee = (amount * BigInt(30)) / BigInt(10000); // 0.3% fee for Tier 3

      // Initial fee balance
      const initialFeeBalance = await gasStation.totalFeesCollected(usdcAddress);

      // Execute first exchange
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount);
      await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount,
        destination: await user.getAddress(),
      });

      // Check fees after first exchange
      const feesAfterFirstExchange = await gasStation.totalFeesCollected(usdcAddress);
      expect(feesAfterFirstExchange).to.equal(initialFeeBalance + fee);

      // Execute second exchange
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), amount);
      await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: amount,
        destination: await user.getAddress(),
      });

      // Check fees after second exchange
      const feesAfterSecondExchange = await gasStation.totalFeesCollected(usdcAddress);
      expect(feesAfterSecondExchange).to.equal(feesAfterFirstExchange + fee);

      // Check total user volume
      const userVolume = await gasStation.getUserVolume(await user.getAddress(), usdcAddress);
      expect(userVolume).to.equal(amount * BigInt(2)); // Should be 2x the amount
    });
  });

  describe("Fee Module Edge Cases and Security", function () {
    beforeEach(async function () {
      const fixture = await loadFixture(deployFixture);
      gasStation = fixture.gasStation;
      mockUSDC = fixture.mockUSDC;
      mockPriceFeed = fixture.mockPriceFeed;
      owner = fixture.owner;
      user = fixture.user;
      otherUser = fixture.otherUser;

      // Create a vault for GasStation to use for exchanges
      const vaultFactory = fixture.vaultFactory;
      const gasStationAddress = await gasStation.getAddress();

      // Create a vault for the GasStation
      await vaultFactory.createVault(gasStationAddress);
      const vaultAddress = await vaultFactory.getLastVaultByOwner(gasStationAddress);

      // Set the gasStation address in the Vault contract
      await gasStation.setVaultGasStation(vaultAddress, gasStationAddress);

      // Fund the vault with ETH
      await owner.sendTransaction({
        to: vaultAddress,
        value: ethers.parseEther("10"),
      });
    });

    it("should handle fee calculation for very small amounts", async function () {
      const usdcAddress = await mockUSDC.getAddress();

      // Get the minimum deposit amount
      const minDepositAmount = await gasStation.minDepositAmount();

      // Use an amount slightly above the minimum deposit amount
      const smallAmount = minDepositAmount + BigInt(1); // min + 1 wei
      const expectedFee = (smallAmount * BigInt(50)) / BigInt(10000); // 0.5% fee

      // Calculate fee
      const calculatedFee = await gasStation.calculateFee(usdcAddress, smallAmount);
      expect(calculatedFee).to.equal(expectedFee);

      // Mint tokens for the user
      await mockUSDC.mint(await user.getAddress(), smallAmount);

      // Execute exchange with small amount
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), smallAmount);
      const tx = await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: smallAmount,
        destination: await user.getAddress(),
      });

      // Check fee collection event
      await expect(tx).to.emit(gasStation, "FeesCollected").withArgs(usdcAddress, expectedFee);
    });

    it("should handle fee calculation for very large amounts", async function () {
      const usdcAddress = await mockUSDC.getAddress();

      // Set a high max deposit limit to allow large amounts
      const highMaxDeposit = ethers.parseUnits("1000000", 6); // 1,000,000 USDC
      await gasStation
        .connect(owner)
        .setDepositLimits(await gasStation.minDepositAmount(), highMaxDeposit);

      // Large amount (10,000 USDC)
      const largeAmount = ethers.parseUnits("10000", 6); // 10,000 USDC
      const expectedFee = (largeAmount * BigInt(30)) / BigInt(10000); // 0.3% of 10,000 USDC

      // Calculate fee
      const calculatedFee = await gasStation.calculateFee(usdcAddress, largeAmount);
      expect(calculatedFee).to.equal(expectedFee);

      // Mint enough tokens for the user
      await mockUSDC.mint(await user.getAddress(), largeAmount);

      // Fund the vault with enough ETH
      const ethAmount = await gasStation.calculateEthAmount(usdcAddress, largeAmount - expectedFee);
      const vaultAddress = await gasStation.findBestVault(ethAmount);
      await owner.sendTransaction({
        to: vaultAddress[0],
        value: ethAmount * BigInt(2), // Double the amount to ensure enough ETH
      });

      // Execute exchange with large amount
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), largeAmount);
      const tx = await gasStation.connect(user).exchange({
        token: usdcAddress,
        amount: largeAmount,
        destination: await user.getAddress(),
      });

      // Check fee collection event
      await expect(tx).to.emit(gasStation, "FeesCollected").withArgs(usdcAddress, expectedFee);
    });

    it("should handle fee calculation for amounts at tier boundaries", async function () {
      const usdcAddress = await mockUSDC.getAddress();

      // Amount exactly at the boundary between Tier 1 and Tier 2 (100 USDC)
      const boundaryAmount1 = ethers.parseUnits("100", 6); // 100 USDC
      // Should use Tier 2 fee (0.4%) since it's >= 100 USDC
      const expectedFee1 = (boundaryAmount1 * BigInt(40)) / BigInt(10000);

      // Calculate fee
      const calculatedFee1 = await gasStation.calculateFee(usdcAddress, boundaryAmount1);
      expect(calculatedFee1).to.equal(expectedFee1);

      // Amount exactly at the boundary between Tier 2 and Tier 3 (500 USDC)
      const boundaryAmount2 = ethers.parseUnits("500", 6); // 500 USDC
      // Should use Tier 3 fee (0.3%) since it's >= 500 USDC
      const expectedFee2 = (boundaryAmount2 * BigInt(30)) / BigInt(10000);

      // Calculate fee
      const calculatedFee2 = await gasStation.calculateFee(usdcAddress, boundaryAmount2);
      expect(calculatedFee2).to.equal(expectedFee2);
    });

    it("should handle fee calculation for unsupported tokens", async function () {
      // Create a new token that is not supported
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const unsupportedToken = await MockERC20Factory.deploy("Unsupported Token", "UNSUP", 18);

      // Attempt to calculate fee for unsupported token
      await expect(
        gasStation.calculateFee(await unsupportedToken.getAddress(), 100)
      ).to.be.revertedWithCustomError(gasStation, "TokenNotSupported");
    });

    it("should handle fee calculation when there are no fee tiers", async function () {
      // Create and add a new token
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20Factory.deploy("New Token", "NEW", 18);
      const newTokenAddress = await newToken.getAddress();

      // Create a mock price feed for the new token
      const MockPriceFeedFactory = await ethers.getContractFactory("MockPriceFeed");
      const newTokenPriceFeed = await MockPriceFeedFactory.deploy();
      await newTokenPriceFeed.setPrice(ethers.parseUnits("1", 8)); // Set price to $1

      // Add the new token to supported tokens
      await gasStation
        .connect(owner)
        .addPaymentToken(newTokenAddress, await newTokenPriceFeed.getAddress());

      // At this point, the new token has no fee tiers defined

      // Calculate fee for the new token
      const amount = ethers.parseUnits("100", 18);
      const calculatedFee = await gasStation.calculateFee(newTokenAddress, amount);

      // Should return 0 since there are no fee tiers
      expect(calculatedFee).to.equal(0);

      // Add a fee tier for the new token
      await gasStation.connect(owner).addFeeTier(
        newTokenAddress,
        0,
        50 // 0.5%
      );

      // Calculate fee again
      const expectedFee = (amount * BigInt(50)) / BigInt(10000);
      const newCalculatedFee = await gasStation.calculateFee(newTokenAddress, amount);

      // Should now return the expected fee
      expect(newCalculatedFee).to.equal(expectedFee);
    });

    it("should handle fee tier management security", async function () {
      const usdcAddress = await mockUSDC.getAddress();

      // Try to add a fee tier with fee exceeding max fee
      const maxFee = await (await gasStation.feeConfig()).maxFeeBps;
      const excessiveFee = maxFee + BigInt(1);

      await expect(gasStation.connect(owner).addFeeTier(usdcAddress, 0, excessiveFee))
        .to.be.revertedWithCustomError(gasStation, "MaxFeeExceeded")
        .withArgs(excessiveFee, maxFee);

      // Increase max fee
      const newMaxFee = 100; // 1%
      await gasStation.connect(owner).setMaxFeeBps(newMaxFee);

      // Now adding the previously excessive fee should work
      await gasStation
        .connect(owner)
        .addFeeTier(usdcAddress, ethers.parseUnits("2000", 6), excessiveFee);

      // Verify the tier was added
      const tiers = await gasStation.getFeeTiers(usdcAddress);
      const lastTier = tiers[tiers.length - 1];
      expect(lastTier.feeBps).to.equal(excessiveFee);
    });
  });
});
