import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { GasOptimizer } from "../typechain-types";

describe("GasOptimizer", function () {
  let gasOptimizer: GasOptimizer;
  let owner: any;
  let user1: any;
  let user2: any;
  let ownerAddress: string;
  let user1Address: string;
  let user2Address: string;

  // Use BigInt for gas parameters
  const defaultMaxPriorityFeePerGas = BigInt(2 * 10 ** 9); // 2 gwei
  const defaultMaxFeePerGas = BigInt(50 * 10 ** 9); // 50 gwei
  const minPriorityFeePerGas = BigInt(1 * 10 ** 9); // 1 gwei
  const maxPriorityFeePerGasLimit = BigInt(100 * 10 ** 9); // 100 gwei

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();
    ownerAddress = await owner.getAddress();
    user1Address = await user1.getAddress();
    user2Address = await user2.getAddress();

    const GasOptimizerFactory = await ethers.getContractFactory("GasOptimizer");
    gasOptimizer = (await upgrades.deployProxy(
      GasOptimizerFactory,
      [
        defaultMaxPriorityFeePerGas,
        defaultMaxFeePerGas,
        minPriorityFeePerGas,
        maxPriorityFeePerGasLimit,
      ],
      { initializer: "initialize" }
    )) as unknown as GasOptimizer;

    // Fund the gas optimizer with some ETH for tests
    await owner.sendTransaction({
      to: await gasOptimizer.getAddress(),
      value: ethers.parseEther("10"),
    });
  });

  describe("Initialization", function () {
    it("should initialize with correct values", async function () {
      expect(await gasOptimizer.defaultMaxPriorityFeePerGas()).to.equal(
        defaultMaxPriorityFeePerGas
      );
      expect(await gasOptimizer.defaultMaxFeePerGas()).to.equal(defaultMaxFeePerGas);
      expect(await gasOptimizer.minPriorityFeePerGas()).to.equal(minPriorityFeePerGas);
      expect(await gasOptimizer.maxPriorityFeePerGas()).to.equal(maxPriorityFeePerGasLimit);
      expect(await gasOptimizer.dynamicFeeEnabled()).to.equal(false);
    });
  });

  describe("Gas Parameters", function () {
    it("should update gas parameters", async function () {
      const newDefaultMaxPriorityFeePerGas = BigInt(3 * 10 ** 9); // 3 gwei
      const newDefaultMaxFeePerGas = BigInt(60 * 10 ** 9); // 60 gwei
      const newMinPriorityFeePerGas = BigInt(1.5 * 10 ** 9); // 1.5 gwei
      const newMaxPriorityFeePerGas = BigInt(120 * 10 ** 9); // 120 gwei

      await gasOptimizer.updateGasParameters(
        newDefaultMaxPriorityFeePerGas,
        newDefaultMaxFeePerGas,
        newMinPriorityFeePerGas,
        newMaxPriorityFeePerGas
      );

      expect(await gasOptimizer.defaultMaxPriorityFeePerGas()).to.equal(
        newDefaultMaxPriorityFeePerGas
      );
      expect(await gasOptimizer.defaultMaxFeePerGas()).to.equal(newDefaultMaxFeePerGas);
      expect(await gasOptimizer.minPriorityFeePerGas()).to.equal(newMinPriorityFeePerGas);
      expect(await gasOptimizer.maxPriorityFeePerGas()).to.equal(newMaxPriorityFeePerGas);
    });

    it("should revert when min priority fee is greater than max", async function () {
      const newMinPriorityFeePerGas = BigInt(150 * 10 ** 9); // 150 gwei
      const newMaxPriorityFeePerGasTest = BigInt(120 * 10 ** 9); // 120 gwei

      await expect(
        gasOptimizer.updateGasParameters(
          defaultMaxPriorityFeePerGas,
          defaultMaxFeePerGas,
          newMinPriorityFeePerGas,
          newMaxPriorityFeePerGasTest
        )
      ).to.be.revertedWithCustomError(gasOptimizer, "InvalidParameters");
    });

    it("should toggle dynamic fee", async function () {
      expect(await gasOptimizer.dynamicFeeEnabled()).to.equal(false);

      await gasOptimizer.toggleDynamicFee(true);
      expect(await gasOptimizer.dynamicFeeEnabled()).to.equal(true);

      await gasOptimizer.toggleDynamicFee(false);
      expect(await gasOptimizer.dynamicFeeEnabled()).to.equal(false);
    });

    it("should set gas price oracle", async function () {
      await gasOptimizer.setGasPriceOracle(user1Address);
      expect(await gasOptimizer.gasPriceOracle()).to.equal(user1Address);
    });

    it("should revert when setting gas price oracle to zero address", async function () {
      const zeroAddress = "0x0000000000000000000000000000000000000000";
      await expect(gasOptimizer.setGasPriceOracle(zeroAddress)).to.be.revertedWithCustomError(
        gasOptimizer,
        "InvalidAddress"
      );
    });
  });

  describe("EIP-1559 Transactions", function () {
    it("should send ETH using EIP-1559 parameters", async function () {
      const initialBalance = await ethers.provider.getBalance(user2Address);
      const amount = ethers.parseEther("1");

      await gasOptimizer.sendEthEIP1559(
        user2Address,
        amount,
        BigInt(2 * 10 ** 9), // 2 gwei
        BigInt(50 * 10 ** 9) // 50 gwei
      );

      const finalBalance = await ethers.provider.getBalance(user2Address);
      expect(finalBalance - initialBalance).to.equal(amount);
    });

    it("should use default gas parameters when zeros are provided", async function () {
      const initialBalance = await ethers.provider.getBalance(user2Address);
      const amount = ethers.parseEther("1");

      await gasOptimizer.sendEthEIP1559(user2Address, amount, 0, 0);

      const finalBalance = await ethers.provider.getBalance(user2Address);
      expect(finalBalance - initialBalance).to.equal(amount);
    });

    it("should revert when sending to zero address", async function () {
      const zeroAddress = "0x0000000000000000000000000000000000000000";
      await expect(
        gasOptimizer.sendEthEIP1559(
          zeroAddress,
          ethers.parseEther("1"),
          BigInt(2 * 10 ** 9), // 2 gwei
          BigInt(50 * 10 ** 9) // 50 gwei
        )
      ).to.be.revertedWithCustomError(gasOptimizer, "InvalidAddress");
    });

    it("should revert when sending zero amount", async function () {
      await expect(
        gasOptimizer.sendEthEIP1559(
          user2Address,
          0,
          BigInt(2 * 10 ** 9), // 2 gwei
          BigInt(50 * 10 ** 9) // 50 gwei
        )
      ).to.be.revertedWithCustomError(gasOptimizer, "InvalidAmount");
    });
  });

  describe("Gas Parameters Retrieval", function () {
    it("should get current gas parameters", async function () {
      const [currentBaseFee, currentMaxPriorityFeePerGas, currentMaxFeePerGas] =
        await gasOptimizer.getGasParameters();

      // In Hardhat network, baseFee might be 0, so we just check it's a number
      expect(typeof currentBaseFee).to.equal("bigint");
      expect(currentMaxPriorityFeePerGas).to.equal(defaultMaxPriorityFeePerGas);
      expect(currentMaxFeePerGas).to.equal(defaultMaxFeePerGas);
    });

    it("should get dynamic gas parameters when enabled", async function () {
      await gasOptimizer.toggleDynamicFee(true);

      const [currentBaseFee, currentMaxPriorityFeePerGas, currentMaxFeePerGas] =
        await gasOptimizer.getGasParameters();

      // In Hardhat network, baseFee might be 0, so we just check it's a number
      expect(typeof currentBaseFee).to.equal("bigint");
      expect(currentMaxPriorityFeePerGas).to.be.gte(minPriorityFeePerGas);
      expect(currentMaxPriorityFeePerGas).to.be.lte(maxPriorityFeePerGasLimit);
      // Check maxFeePerGas is at least equal to baseFee + maxPriorityFeePerGas
      expect(currentMaxFeePerGas).to.be.gte(currentBaseFee + currentMaxPriorityFeePerGas);
    });
  });

  describe("Access Control", function () {
    it("should revert when non-owner tries to update gas parameters", async function () {
      await expect(
        gasOptimizer.connect(user1).updateGasParameters(
          BigInt(3 * 10 ** 9), // 3 gwei
          BigInt(60 * 10 ** 9), // 60 gwei
          BigInt(1.5 * 10 ** 9), // 1.5 gwei
          BigInt(120 * 10 ** 9) // 120 gwei
        )
      ).to.be.revertedWithCustomError(gasOptimizer, "OwnableUnauthorizedAccount");
    });

    it("should revert when non-owner tries to toggle dynamic fee", async function () {
      await expect(
        gasOptimizer.connect(user1).toggleDynamicFee(true)
      ).to.be.revertedWithCustomError(gasOptimizer, "OwnableUnauthorizedAccount");
    });

    it("should revert when non-owner tries to set gas price oracle", async function () {
      await expect(
        gasOptimizer.connect(user1).setGasPriceOracle(user2Address)
      ).to.be.revertedWithCustomError(gasOptimizer, "OwnableUnauthorizedAccount");
    });
  });

  describe("Pausability", function () {
    it("should pause and unpause the contract", async function () {
      await gasOptimizer.pause();
      expect(await gasOptimizer.paused()).to.equal(true);

      await expect(
        gasOptimizer.sendEthEIP1559(
          user2Address,
          ethers.parseEther("1"),
          BigInt(2 * 10 ** 9), // 2 gwei
          BigInt(50 * 10 ** 9) // 50 gwei
        )
      ).to.be.revertedWithCustomError(gasOptimizer, "EnforcedPause");

      await gasOptimizer.unpause();
      expect(await gasOptimizer.paused()).to.equal(false);

      // Should work after unpausing
      await gasOptimizer.sendEthEIP1559(
        user2Address,
        ethers.parseEther("1"),
        BigInt(2 * 10 ** 9), // 2 gwei
        BigInt(50 * 10 ** 9) // 50 gwei
      );
    });
  });
});
