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

describe("GasStation", function () {
  let gasStation: GasStation & Contract;
  let vaultFactory: VaultFactory & Contract;
  let mockUSDC: MockERC20 & Contract;
  let mockPriceFeed: MockPriceFeed & Contract;
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

    const VaultFactoryFactory = await ethers.getContractFactory("VaultFactory");
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

    vaultFactory = (await upgrades.deployProxy(VaultFactoryFactory, [
      await vaultImplementation.getAddress(),
      await tokenWhitelist.getAddress(),
    ])) as VaultFactory & Contract;
    await vaultFactory.waitForDeployment();

    const GasStationFactory = await ethers.getContractFactory("GasStation", owner);
    gasStation = (await upgrades.deployProxy(
      GasStationFactory,
      [
        await mockUSDC.getAddress(),
        await mockPriceFeed.getAddress(),
        MIN_DEPOSIT,
        MAX_DEPOSIT,
        await vaultFactory.getAddress(),
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

    // Fund the vault with ETH
    await owner.sendTransaction({
      to: vaultAddress,
      value: ethers.parseEther("10"),
    });
    await network.provider.send("evm_mine");

    await mockUSDC.connect(user).approve(await gasStation.getAddress(), depositAmount * 2n);
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
          ethers.ZeroAddress,
          await mockPriceFeed.getAddress(),
          MIN_DEPOSIT,
          MAX_DEPOSIT,
          await vaultFactory.getAddress(),
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
    it("should exchange tokens for ETH using regular approve", async function () {
      const userAddress = await user.getAddress();
      const userBalanceBefore = await ethers.provider.getBalance(userAddress);

      await gasStation
        .connect(user)
        .exchange(await mockUSDC.getAddress(), depositAmount, userAddress);

      const userBalanceAfter = await ethers.provider.getBalance(userAddress);
      expect(userBalanceAfter).to.be.gt(userBalanceBefore);
    });

    it("should exchange tokens for ETH using permit", async function () {
      const userAddress = await user.getAddress();
      const userBalanceBefore = await ethers.provider.getBalance(userAddress);

      // Get permit signature
      const nonce = await mockUSDC.nonces(userAddress);
      const domain = {
        name: await mockUSDC.name(),
        version: "1",
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await mockUSDC.getAddress(),
      };

      const types = {
        Permit: [
          { name: "owner", type: "address" },
          { name: "spender", type: "address" },
          { name: "value", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        owner: userAddress,
        spender: await gasStation.getAddress(),
        value: depositAmount,
        nonce: nonce,
        deadline: deadline,
      };

      const signature = await user.signTypedData(domain, types, value);
      const { v, r, s } = ethers.Signature.from(signature);

      await gasStation
        .connect(user)
        .exchangeWithPermit(
          await mockUSDC.getAddress(),
          depositAmount,
          userAddress,
          deadline,
          v,
          r,
          s
        );

      const userBalanceAfter = await ethers.provider.getBalance(userAddress);
      expect(userBalanceAfter).to.be.gt(userBalanceBefore);
    });

    it("should revert on expired deadline in permit", async function () {
      const expiredDeadline = (await time.latest()) - 1;
      await expect(
        gasStation
          .connect(user)
          .exchangeWithPermit(
            await mockUSDC.getAddress(),
            depositAmount,
            await user.getAddress(),
            expiredDeadline,
            0,
            ethers.ZeroHash,
            ethers.ZeroHash
          )
      ).to.be.revertedWithCustomError(gasStation, "ExpiredDeadline");
    });

    it("should revert when amount below minimum", async function () {
      const smallAmount = MIN_DEPOSIT / 2n; // Use BigInt division
      await expect(
        gasStation.exchange(await mockUSDC.getAddress(), smallAmount, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(gasStation, "AmountBelowMinimum");
    });

    it("should revert when amount above maximum", async function () {
      const largeAmount = MAX_DEPOSIT * 2n; // Use BigInt multiplication
      await expect(
        gasStation.exchange(await mockUSDC.getAddress(), largeAmount, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(gasStation, "AmountAboveMaximum");
    });

    it("should revert when destination is GasStation", async function () {
      await expect(
        gasStation.exchange(
          await mockUSDC.getAddress(),
          depositAmount,
          await gasStation.getAddress()
        )
      ).to.be.revertedWithCustomError(gasStation, "InvalidDestination");
    });

    it("should respect rate limit per block", async function () {
      const smallAmount = MIN_DEPOSIT;

      // Turn off automining to ensure all txs are in the same block
      await network.provider.send("evm_setAutomine", [false]);
      await network.provider.send("evm_setIntervalMining", [0]);

      console.log("Initial block number:", await ethers.provider.getBlockNumber());

      // Get starting nonce
      const startNonce = await ethers.provider.getTransactionCount(await user.getAddress());

      // Queue up MAX_DEPOSITS_PER_BLOCK transactions
      const txPromises = [];
      for (let i = 0; i < MAX_DEPOSITS_PER_BLOCK; i++) {
        // Create the transaction but don't send it yet
        const tx = await gasStation
          .connect(user)
          .exchange.populateTransaction(
            await mockUSDC.getAddress(),
            smallAmount,
            ethers.ZeroAddress
          );

        // Send the transaction with explicit nonce
        const txPromise = user.sendTransaction({
          ...tx,
          nonce: startNonce + i,
          gasLimit: 500000, // Set explicit gas limit
        });
        txPromises.push(txPromise);
      }

      // Queue up one more transaction that should fail
      const failingTx = await gasStation
        .connect(user)
        .exchange.populateTransaction(await mockUSDC.getAddress(), smallAmount, ethers.ZeroAddress);
      txPromises.push(
        user.sendTransaction({
          ...failingTx,
          nonce: startNonce + MAX_DEPOSITS_PER_BLOCK,
          gasLimit: 500000,
        })
      );

      // Wait for all transactions to be queued
      await Promise.all(txPromises);

      // Mine the block with all transactions
      await network.provider.send("evm_mine");
      const newBlockNum = await ethers.provider.getBlockNumber();

      // Get the block to verify transactions were included
      const block = await ethers.provider.getBlock(newBlockNum);

      // Get the current deposits count for this block
      await gasStation.depositsPerBlock(newBlockNum);

      // Get the transaction receipt for the last transaction
      const lastTxHash = block?.transactions[block.transactions.length - 1];
      if (lastTxHash) {
        const receipt = await ethers.provider.getTransactionReceipt(lastTxHash);
        expect(receipt?.status).to.equal(0); // 0 means transaction failed
      }

      // Reset mining settings
      await network.provider.send("evm_setAutomine", [true]);
    });

    it("should use default token when token address is zero", async function () {
      // Debug initial state
      await vaultFactory.getLastVaultByOwner(await gasStation.getAddress());

      const userAddress = await user.getAddress();
      const userBalanceBefore = await ethers.provider.getBalance(userAddress);
      const ethAmount = await gasStation.calculateEthAmount(
        await mockUSDC.getAddress(),
        depositAmount
      );

      // Ensure automine is on
      await network.provider.send("evm_setAutomine", [true]);

      // Execute the exchange
      await gasStation.connect(user).exchange(ethers.ZeroAddress, depositAmount, userAddress);
      await network.provider.send("evm_mine");

      const userBalanceAfter = await ethers.provider.getBalance(userAddress);

      // Compare final balance with expected amount, allowing for gas costs
      expect(userBalanceAfter).to.be.gt(userBalanceBefore);
      expect(userBalanceAfter).to.be.closeTo(
        userBalanceBefore + ethAmount,
        ethers.parseEther("0.1") // Increased margin to account for gas costs
      );
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

      await expect(
        gasStation
          .connect(owner)
          .emergencyWithdrawToken(await mockUSDC.getAddress(), amount, await owner.getAddress())
      )
        .to.emit(gasStation, "EmergencyWithdrawal")
        .withArgs(await mockUSDC.getAddress(), amount, await owner.getAddress());

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
        gasStation
          .connect(owner)
          .emergencyWithdrawToken(await mockUSDC.getAddress(), amount, await owner.getAddress())
      ).to.be.revertedWithCustomError(gasStation, "NotInEmergencyMode");

      // Debug: Check final state
      console.log("Final paused state:", await gasStation.paused());
    });
  });
});
