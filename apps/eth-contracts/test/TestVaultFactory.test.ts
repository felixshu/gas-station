import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import type { TestVaultFactory, TokenWhitelist } from "../typechain-types";
import { deployVaultFactoryWithLibraries } from "./helpers/fixtures";

describe("TestVaultFactory Pausability Tests", function () {
  // Common variables
  let testVaultFactory: TestVaultFactory;
  let tokenWhitelist: TokenWhitelist;
  let owner: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let vaultOwner: HardhatEthersSigner;

  async function deployTestFixture() {
    [owner, user, vaultOwner] = await ethers.getSigners();

    // Deploy TokenWhitelist
    const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");
    tokenWhitelist = (await upgrades.deployProxy(TokenWhitelistFactory, [], {
      initializer: "initialize",
      kind: "uups",
    })) as TokenWhitelist;
    await tokenWhitelist.waitForDeployment();

    // Deploy VaultFactory with libraries first to get the vault implementation
    const result = await deployVaultFactoryWithLibraries(owner, await tokenWhitelist.getAddress());
    const vaultImplementation = result.vaultImplementation;

    // Deploy TestVaultFactory
    const TestVaultFactoryFactory = await ethers.getContractFactory("TestVaultFactory");
    testVaultFactory = (await upgrades.deployProxy(
      TestVaultFactoryFactory,
      [await vaultImplementation.getAddress(), await tokenWhitelist.getAddress()],
      {
        initializer: "initialize",
        kind: "uups",
      }
    )) as TestVaultFactory;
    await testVaultFactory.waitForDeployment();

    return {
      testVaultFactory,
      tokenWhitelist,
      owner,
      user,
      vaultOwner,
    };
  }

  describe("Pausability", function () {
    it("should be able to pause and unpause the contract", async function () {
      const { testVaultFactory } = await loadFixture(deployTestFixture);

      // Verify the contract is not paused initially
      expect(await testVaultFactory.paused()).to.be.false;

      // Pause the contract
      await testVaultFactory.pause();
      expect(await testVaultFactory.paused()).to.be.true;

      // Unpause the contract
      await testVaultFactory.unpause();
      expect(await testVaultFactory.paused()).to.be.false;
    });

    it("should not allow non-owner to pause or unpause", async function () {
      const { testVaultFactory, user } = await loadFixture(deployTestFixture);

      // Try to pause as non-owner
      await expect(testVaultFactory.connect(user).pause()).to.be.revertedWithCustomError(
        testVaultFactory,
        "OwnableUnauthorizedAccount"
      );

      // Pause as owner
      await testVaultFactory.pause();

      // Try to unpause as non-owner
      await expect(testVaultFactory.connect(user).unpause()).to.be.revertedWithCustomError(
        testVaultFactory,
        "OwnableUnauthorizedAccount"
      );
    });

    it("should prevent vault creation when paused", async function () {
      const { testVaultFactory, vaultOwner } = await loadFixture(deployTestFixture);

      // Create a vault when not paused
      await testVaultFactory.createVault(vaultOwner.address);
      expect(await testVaultFactory.getVaultCountByOwner(vaultOwner.address)).to.equal(1);

      // Pause the contract
      await testVaultFactory.pause();

      // Try to create a vault when paused
      await expect(testVaultFactory.createVault(vaultOwner.address)).to.be.revertedWithCustomError(
        testVaultFactory,
        "EnforcedPause"
      );
    });

    it("should prevent multiple vault creation when paused", async function () {
      const { testVaultFactory, vaultOwner, user } = await loadFixture(deployTestFixture);

      // Pause the contract
      await testVaultFactory.pause();

      // Try to create multiple vaults when paused
      const owners = [vaultOwner.address, user.address];
      await expect(testVaultFactory.createMultipleVaults(owners)).to.be.revertedWithCustomError(
        testVaultFactory,
        "EnforcedPause"
      );
    });

    it("should prevent implementation update when paused", async function () {
      const { testVaultFactory } = await loadFixture(deployTestFixture);

      // Deploy a new vault implementation
      const VaultImpl = await ethers.getContractFactory("Vault");
      const newVaultImplementation = await VaultImpl.deploy();
      await newVaultImplementation.waitForDeployment();

      // Pause the contract
      await testVaultFactory.pause();

      // Try to update implementation when paused
      await expect(
        testVaultFactory.updateImplementation(await newVaultImplementation.getAddress())
      ).to.be.revertedWithCustomError(testVaultFactory, "EnforcedPause");
    });

    it("should prevent whitelist update when paused", async function () {
      const { testVaultFactory } = await loadFixture(deployTestFixture);

      // Deploy a new token whitelist
      const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");
      const newTokenWhitelist = await upgrades.deployProxy(TokenWhitelistFactory, [], {
        initializer: "initialize",
        kind: "uups",
      });
      await newTokenWhitelist.waitForDeployment();

      // Pause the contract
      await testVaultFactory.pause();

      // Try to update whitelist when paused
      await expect(
        testVaultFactory.updateWhitelist(await newTokenWhitelist.getAddress())
      ).to.be.revertedWithCustomError(testVaultFactory, "EnforcedPause");
    });

    it("should allow read-only operations when paused", async function () {
      const { testVaultFactory, vaultOwner } = await loadFixture(deployTestFixture);

      // Create a vault before pausing
      await testVaultFactory.createVault(vaultOwner.address);
      const vaultAddress = await testVaultFactory.getLastVaultByOwner(vaultOwner.address);

      // Pause the contract
      await testVaultFactory.pause();

      // Read-only operations should still work
      expect(await testVaultFactory.getVaultCountByOwner(vaultOwner.address)).to.equal(1);
      expect(await testVaultFactory.getLastVaultByOwner(vaultOwner.address)).to.equal(vaultAddress);
      expect(await testVaultFactory.isVault(vaultAddress)).to.be.true;
      expect(await testVaultFactory.getVaultCount()).to.equal(1);
    });

    it("should resume normal operation after unpausing", async function () {
      const { testVaultFactory, vaultOwner } = await loadFixture(deployTestFixture);

      // Pause the contract
      await testVaultFactory.pause();

      // Unpause the contract
      await testVaultFactory.unpause();

      // Should be able to create a vault after unpausing
      await testVaultFactory.createVault(vaultOwner.address);
      expect(await testVaultFactory.getVaultCountByOwner(vaultOwner.address)).to.equal(1);
    });
  });
});
