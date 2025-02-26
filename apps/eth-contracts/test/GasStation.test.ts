import { expect } from "chai";
import { ethers, upgrades, network } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";
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
import { deployVaultFactoryWithLibraries } from "./helpers/fixtures";

describe("GasStation", function () {
  let gasStation: GasStation & Contract;
  let vaultFactory: VaultFactory & Contract;
  let mockUSDC: MockERC20 & Contract;
  let mockPriceFeed: MockPriceFeed & Contract;
  let tokenWhitelist: TokenWhitelist & Contract;
  let owner: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let otherUser: HardhatEthersSigner;

  const INITIAL_SUPPLY = ethers.parseUnits("1000000", 6); // 1M USDC
  const MIN_DEPOSIT = ethers.parseUnits("10", 6); // 10 USDC
  const MAX_DEPOSIT = ethers.parseUnits("10000", 6); // 10,000 USDC
  const ETH_PRICE = ethers.parseUnits("2000", 8); // $2000 per ETH
  const MAX_DEPOSITS_PER_BLOCK = 10;
  const depositAmount = ethers.parseUnits("1000", 6); // 1000 USDC
  const deadline = ethers.MaxUint256;

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

    const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");
    const tokenWhitelist = (await upgrades.deployProxy(
      TokenWhitelistFactory,
      []
    )) as TokenWhitelist & Contract;
    await tokenWhitelist.waitForDeployment();

    await tokenWhitelist.addToken(await mockUSDC.getAddress());

    // Deploy VaultFactory with TokenWhitelist using our helper function
    const result = await deployVaultFactoryWithLibraries(owner, await tokenWhitelist.getAddress());
    vaultFactory = result.vaultFactory as VaultFactory & Contract;

    // Deploy GasStation
    const GasStationFactory = await ethers.getContractFactory("GasStation", owner);
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

    return {
      gasStation,
      vaultFactory,
      mockUSDC,
      mockPriceFeed,
      tokenWhitelist,
      owner,
      user,
      otherUser,
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployFixture);
    gasStation = fixture.gasStation;
    vaultFactory = fixture.vaultFactory;
    mockUSDC = fixture.mockUSDC;
    mockPriceFeed = fixture.mockPriceFeed;
    tokenWhitelist = fixture.tokenWhitelist;
    owner = fixture.owner;
    user = fixture.user;
    otherUser = fixture.otherUser;

    // Ensure automine is on for setup
    await network.provider.send("evm_setAutomine", [true]);

    const gasStationAddress = await gasStation.getAddress();

    // Set up VaultFactory in GasStation
    await gasStation.setVaultFactory(await vaultFactory.getAddress());

    // Manually create a vault for GasStation
    await vaultFactory.connect(owner).createVault(gasStationAddress);

    // Get the vault address
    const vaultAddress = await vaultFactory.getLastVaultByOwner(gasStationAddress);

    // Set the gasStation address in the Vault contract
    const vault = await ethers.getContractAt("Vault", vaultAddress);
    await gasStation.connect(owner).setVaultGasStation(vaultAddress, gasStationAddress);

    // Fund the vault with ETH
    await owner.sendTransaction({
      to: vaultAddress,
      value: ethers.parseEther("10"),
    });
    await network.provider.send("evm_mine");

    await mockUSDC.connect(user).approve(await gasStation.getAddress(), depositAmount);
  });

  describe("Initialization", function () {
    it("should initialize with correct values", async function () {
      expect(await gasStation.defaultToken()).to.equal(await mockUSDC.getAddress());
      expect(await gasStation.minDepositAmount()).to.equal(MIN_DEPOSIT);
      expect(await gasStation.maxDepositAmount()).to.equal(MAX_DEPOSIT);
      expect(await gasStation.vaultFactory()).to.equal(await vaultFactory.getAddress());
      expect(await gasStation.owner()).to.equal(await owner.getAddress());
    });

    it("should revert if initialized with zero address", async function () {
      const GasStationFactory = await ethers.getContractFactory("GasStation");
      await expect(
        upgrades.deployProxy(GasStationFactory, [
          {
            defaultToken: ethers.ZeroAddress,
            defaultPriceFeed: await mockPriceFeed.getAddress(),
            minDepositAmount: MIN_DEPOSIT,
            maxDepositAmount: MAX_DEPOSIT,
            vaultFactory: await vaultFactory.getAddress(),
          },
        ])
      ).to.be.revertedWithCustomError(gasStation, "InvalidAddress");
    });
  });

  describe("Payment Token Management", function () {
    const newTokenPrice = ethers.parseUnits("1", 8); // $1 per token
    let newToken: MockERC20 & Contract;
    let newPriceFeed: MockPriceFeed & Contract;

    beforeEach(async function () {
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      newToken = (await MockERC20Factory.deploy("New Token", "NEW", 18)) as MockERC20 & Contract;

      const MockPriceFeedFactory = await ethers.getContractFactory("MockPriceFeed");
      newPriceFeed = (await MockPriceFeedFactory.deploy()) as MockPriceFeed & Contract;
      await newPriceFeed.setPrice(newTokenPrice);
    });

    it("should add new payment token", async function () {
      await gasStation.addPaymentToken(
        await newToken.getAddress(),
        await newPriceFeed.getAddress()
      );
      const tokenConfig = await gasStation.paymentTokens(await newToken.getAddress());
      expect(tokenConfig.isSupported).to.be.true;
      expect(tokenConfig.decimals).to.equal(18);
      expect(tokenConfig.priceFeed).to.equal(await newPriceFeed.getAddress());
    });

    it("should remove payment token", async function () {
      await gasStation.addPaymentToken(
        await newToken.getAddress(),
        await newPriceFeed.getAddress()
      );
      await gasStation.removePaymentToken(await newToken.getAddress());
      const tokenConfig = await gasStation.paymentTokens(await newToken.getAddress());
      expect(tokenConfig.isSupported).to.be.false;
    });

    it("should not allow non-owner to add token", async function () {
      await expect(
        gasStation
          .connect(user)
          .addPaymentToken(await newToken.getAddress(), await newPriceFeed.getAddress())
      )
        .to.be.revertedWithCustomError(gasStation, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());
    });

    it("should revert when adding token with zero price feed", async function () {
      await expect(
        gasStation.addPaymentToken(await newToken.getAddress(), ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(gasStation, "InvalidAddress");
    });

    it("should revert when adding zero address as token", async function () {
      await expect(
        gasStation.addPaymentToken(ethers.ZeroAddress, await newPriceFeed.getAddress())
      ).to.be.revertedWithCustomError(gasStation, "InvalidAddress");
    });

    it("should revert when removing unsupported token", async function () {
      await expect(
        gasStation.removePaymentToken(await newToken.getAddress())
      ).to.be.revertedWithCustomError(gasStation, "TokenNotSupported");
    });

    it("should not allow non-owner to remove token", async function () {
      await gasStation.addPaymentToken(
        await newToken.getAddress(),
        await newPriceFeed.getAddress()
      );
      await expect(gasStation.connect(user).removePaymentToken(await newToken.getAddress()))
        .to.be.revertedWithCustomError(gasStation, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());
    });
  });

  describe("ETH Amount Calculation", function () {
    it("should calculate correct ETH amount for USDC", async function () {
      const usdcAmount = ethers.parseUnits("2000", 6); // 2000 USDC
      const expectedEth = ethers.parseEther("1"); // 1 ETH at $2000/ETH
      const calculatedEth = await gasStation.calculateEthAmount(
        await mockUSDC.getAddress(),
        usdcAmount
      );
      expect(calculatedEth).to.equal(expectedEth);
    });

    it("should revert on zero amount", async function () {
      await expect(
        gasStation.calculateEthAmount(await mockUSDC.getAddress(), 0)
      ).to.be.revertedWithCustomError(gasStation, "ZeroAmount");
    });

    it("should revert on unsupported token", async function () {
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const unsupportedToken = (await MockERC20Factory.deploy(
        "Unsupported",
        "UNS",
        18
      )) as unknown as MockERC20;
      await expect(
        gasStation.calculateEthAmount(await unsupportedToken.getAddress(), 1000)
      ).to.be.revertedWithCustomError(gasStation, "TokenNotSupported");
    });

    it("should revert on stale price", async function () {
      await time.increase(31 * 60); // 31 minutes
      await expect(
        gasStation.calculateEthAmount(await mockUSDC.getAddress(), ethers.parseUnits("100", 6))
      ).to.be.revertedWithCustomError(gasStation, "StalePrice");
    });

    it("should revert on invalid round id", async function () {
      await mockPriceFeed.setRoundId(0);
      await expect(
        gasStation.calculateEthAmount(await mockUSDC.getAddress(), ethers.parseUnits("100", 6))
      ).to.be.revertedWithCustomError(gasStation, "InvalidEthRoundId");
    });

    it("should revert on negative price", async function () {
      await mockPriceFeed.setPrice(-1);
      await expect(
        gasStation.calculateEthAmount(await mockUSDC.getAddress(), ethers.parseUnits("100", 6))
      ).to.be.revertedWithCustomError(gasStation, "InvalidEthPrice");
    });
  });

  describe("Vault Management", function () {
    it("should find vault with sufficient balance", async function () {
      const requiredEth = ethers.parseEther("5");
      const [, balance] = await gasStation.findBestVault(requiredEth);
      expect(balance).to.be.gte(requiredEth);
    });

    it("should revert when no vault has sufficient balance", async function () {
      const requiredEth = ethers.parseEther("20");
      await expect(gasStation.findBestVault(requiredEth)).to.be.revertedWithCustomError(
        gasStation,
        "InsufficientBalance"
      );
    });
  });

  describe("Token Exchange", function () {
    it("should handle ETH transfers through Vault", async function () {
      // Create a new vault with GasStation as the owner
      await vaultFactory.connect(owner).createVault(await gasStation.getAddress());
      const vaultAddress = await vaultFactory.getLastVaultByOwner(await gasStation.getAddress());

      // Set the gasStation address in the Vault contract
      await gasStation
        .connect(owner)
        .setVaultGasStation(vaultAddress, await gasStation.getAddress());

      // Fund the vault with ETH
      await owner.sendTransaction({
        to: vaultAddress,
        value: ethers.parseEther("10"),
      });

      // Approve USDC for GasStation
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), depositAmount);

      // Get initial balances
      const userBalanceBefore = await ethers.provider.getBalance(await user.getAddress());
      const usdcBalanceBefore = await mockUSDC.balanceOf(await user.getAddress());

      // Calculate expected ETH amount
      const ethAmount = await gasStation.calculateEthAmount(
        await mockUSDC.getAddress(),
        depositAmount
      );

      // Execute the exchange
      const tx = await gasStation.connect(user).exchange({
        token: await mockUSDC.getAddress(),
        amount: depositAmount,
        destination: await user.getAddress(),
      });
      await tx.wait();

      // Get final balances
      const userBalanceAfter = await ethers.provider.getBalance(await user.getAddress());
      const usdcBalanceAfter = await mockUSDC.balanceOf(await user.getAddress());

      // Verify USDC was spent
      expect(usdcBalanceBefore - usdcBalanceAfter).to.equal(depositAmount);

      // Verify ETH was received (accounting for gas costs)
      expect(userBalanceAfter).to.be.gt(userBalanceBefore);
      expect(userBalanceAfter).to.be.closeTo(
        userBalanceBefore + ethAmount - BigInt(tx.gasLimit) * BigInt(tx.maxFeePerGas || 0),
        ethers.parseEther("0.1") // Margin to account for gas costs
      );

      // Verify the event was emitted with correct parameters
      await expect(tx)
        .to.emit(gasStation, "DepositProcessed")
        .withArgs(
          await user.getAddress(),
          await user.getAddress(),
          await mockUSDC.getAddress(),
          depositAmount,
          ethAmount
        );
    });

    it("should handle multiple ETH transfers through different vaults", async function () {
      // Create two vaults with GasStation as the owner
      await vaultFactory.connect(owner).createVault(await gasStation.getAddress());
      const vault1Address = await vaultFactory.getLastVaultByOwner(await gasStation.getAddress());

      // Set the gasStation address in the first Vault contract
      await gasStation
        .connect(owner)
        .setVaultGasStation(vault1Address, await gasStation.getAddress());

      await vaultFactory.connect(owner).createVault(await gasStation.getAddress());
      const vault2Address = await vaultFactory.getLastVaultByOwner(await gasStation.getAddress());

      // Set the gasStation address in the second Vault contract
      await gasStation
        .connect(owner)
        .setVaultGasStation(vault2Address, await gasStation.getAddress());

      // Fund the vaults with ETH
      await owner.sendTransaction({
        to: vault1Address,
        value: ethers.parseEther("5"),
      });

      await owner.sendTransaction({
        to: vault2Address,
        value: ethers.parseEther("5"),
      });

      // Approve USDC for GasStation
      const totalAmount = depositAmount * BigInt(2);
      await mockUSDC.connect(user).approve(await gasStation.getAddress(), totalAmount);

      // Get initial balances
      const vault1BalanceBefore = await ethers.provider.getBalance(vault1Address);
      const vault2BalanceBefore = await ethers.provider.getBalance(vault2Address);

      // Execute two exchanges
      const tx1 = await gasStation.connect(user).exchange({
        token: await mockUSDC.getAddress(),
        amount: depositAmount,
        destination: await user.getAddress(),
      });
      await tx1.wait();

      // Mine a block to ensure the transaction is processed
      await network.provider.send("evm_mine");

      const tx2 = await gasStation.connect(user).exchange({
        token: await mockUSDC.getAddress(),
        amount: depositAmount,
        destination: await user.getAddress(),
      });
      await tx2.wait();

      // Verify the events were emitted
      await expect(tx1).to.emit(gasStation, "DepositProcessed");
      await expect(tx2).to.emit(gasStation, "DepositProcessed");

      // Verify the vault balances have decreased
      const vault1BalanceAfter = await ethers.provider.getBalance(vault1Address);
      const vault2BalanceAfter = await ethers.provider.getBalance(vault2Address);

      // At least one vault should have less than its initial 5 ETH
      expect(vault1BalanceAfter < vault1BalanceBefore || vault2BalanceAfter < vault2BalanceBefore)
        .to.be.true;
    });
  });

  describe("Emergency Functions", function () {
    it("should enable emergency mode", async function () {
      // Ensure the contract is not paused
      expect(await gasStation.paused()).to.be.false;

      // Set automine to true to ensure transaction is mined immediately
      await network.provider.send("evm_setAutomine", [true]);

      await expect(gasStation.connect(owner).enableEmergencyMode()).to.emit(
        gasStation,
        "EmergencyModeEnabled"
      );
      // Mine a new block to ensure the transaction is processed
      await network.provider.send("evm_mine");

      // Verify that the contract is paused
      expect(await gasStation.paused()).to.be.true;
    });

    it("should disable emergency mode", async function () {
      await gasStation.enableEmergencyMode();
      expect(await gasStation.paused()).to.be.true;
      await expect(gasStation.disableEmergencyMode()).to.emit(gasStation, "EmergencyModeDisabled");
      expect(await gasStation.paused()).to.be.false;
    });

    it("should allow emergency withdrawal when paused", async function () {
      const amount = ethers.parseUnits("100", 6);
      await mockUSDC.mint(await gasStation.getAddress(), amount);
      // Verify contract is not paused
      expect(await gasStation.paused()).to.be.false;

      // Verify ownership
      expect(await gasStation.owner()).to.equal(await owner.getAddress());
      await gasStation.enableEmergencyMode();

      // Test emergencyWithdrawToken
      await expect(
        gasStation.connect(owner).emergencyWithdrawToken({
          token: await mockUSDC.getAddress(),
          amount: amount,
          to: await owner.getAddress(),
        })
      ).to.emit(gasStation, "EmergencyWithdrawal");

      expect(await mockUSDC.balanceOf(await owner.getAddress())).to.equal(amount);
    });

    it("should not allow emergency withdrawal when not paused", async function () {
      const amount = ethers.parseUnits("100", 6);
      await mockUSDC.mint(await gasStation.getAddress(), amount);

      // Verify contract is not paused
      expect(await gasStation.paused()).to.be.false;

      // Verify ownership
      expect(await gasStation.owner()).to.equal(await owner.getAddress());

      // Try emergency withdrawal when not paused
      await expect(
        gasStation.connect(owner).emergencyWithdrawToken({
          token: await mockUSDC.getAddress(),
          amount: amount,
          to: await owner.getAddress(),
        })
      ).to.be.revertedWithCustomError(gasStation, "NotInEmergencyMode");

      // Debug: Check final state
      console.log("Final paused state:", await gasStation.paused());
    });
  });
});
