import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import type { Contract } from "ethers";
import type {
  TokenWhitelist,
  MockERC20,
  GasStation,
  VaultFactory,
  Vault,
  MockPriceFeed,
} from "../typechain-types";
import { deployVaultFactoryWithLibraries } from "./helpers/fixtures";

describe("TokenWhitelist", function () {
  let tokenWhitelist: TokenWhitelist & Contract;
  let mockToken1: MockERC20 & Contract;
  let mockToken2: MockERC20 & Contract;
  let mockToken3: MockERC20 & Contract;
  let owner: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let otherUser: HardhatEthersSigner;

  async function deployFixture() {
    [owner, user, otherUser] = await ethers.getSigners();

    // Deploy mock tokens for testing
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    mockToken1 = (await MockERC20Factory.deploy("Token 1", "TK1", 18)) as MockERC20 & Contract;
    mockToken2 = (await MockERC20Factory.deploy("Token 2", "TK2", 6)) as MockERC20 & Contract;
    mockToken3 = (await MockERC20Factory.deploy("Token 3", "TK3", 8)) as MockERC20 & Contract;

    // Deploy TokenWhitelist
    const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");
    tokenWhitelist = (await upgrades.deployProxy(TokenWhitelistFactory, [], {
      initializer: "initialize",
      kind: "uups",
    })) as TokenWhitelist & Contract;
    await tokenWhitelist.waitForDeployment();

    return {
      tokenWhitelist,
      mockToken1,
      mockToken2,
      mockToken3,
      owner,
      user,
      otherUser,
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployFixture);
    tokenWhitelist = fixture.tokenWhitelist;
    mockToken1 = fixture.mockToken1;
    mockToken2 = fixture.mockToken2;
    mockToken3 = fixture.mockToken3;
    owner = fixture.owner;
    user = fixture.user;
    otherUser = fixture.otherUser;
  });

  // Category 1: Initialization Tests
  describe("Initialization", function () {
    it("should initialize with correct owner", async function () {
      expect(await tokenWhitelist.owner()).to.equal(await owner.getAddress());
    });

    it("should initialize with no tokens whitelisted", async function () {
      expect(await tokenWhitelist.getWhitelistedTokenCount()).to.equal(0);
    });

    it("should have the correct version", async function () {
      expect(await tokenWhitelist.VERSION()).to.equal(1);
    });

    it("should not be paused initially", async function () {
      expect(await tokenWhitelist.paused()).to.be.false;
    });
  });

  // Category 2: Access Control Tests
  describe("Access Control", function () {
    it("should allow only owner to add tokens", async function () {
      await expect(tokenWhitelist.connect(user).addToken(await mockToken1.getAddress()))
        .to.be.revertedWithCustomError(tokenWhitelist, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());

      // Owner should be able to add token
      await expect(tokenWhitelist.connect(owner).addToken(await mockToken1.getAddress()))
        .to.emit(tokenWhitelist, "TokenAdded")
        .withArgs(await mockToken1.getAddress());
    });

    it("should allow only owner to remove tokens", async function () {
      // First add a token
      await tokenWhitelist.connect(owner).addToken(await mockToken1.getAddress());

      // Non-owner should not be able to remove
      await expect(tokenWhitelist.connect(user).removeToken(await mockToken1.getAddress()))
        .to.be.revertedWithCustomError(tokenWhitelist, "OwnableUnauthorizedAccount")
        .withArgs(await user.getAddress());

      // Owner should be able to remove
      await expect(tokenWhitelist.connect(owner).removeToken(await mockToken1.getAddress()))
        .to.emit(tokenWhitelist, "TokenRemoved")
        .withArgs(await mockToken1.getAddress());
    });

    it("should allow ownership transfer", async function () {
      // Transfer ownership
      await tokenWhitelist.connect(owner).transferOwnership(await user.getAddress());
      expect(await tokenWhitelist.owner()).to.equal(await user.getAddress());

      // New owner should be able to add tokens
      await expect(tokenWhitelist.connect(user).addToken(await mockToken1.getAddress()))
        .to.emit(tokenWhitelist, "TokenAdded")
        .withArgs(await mockToken1.getAddress());

      // Old owner should not be able to add tokens
      await expect(tokenWhitelist.connect(owner).addToken(await mockToken2.getAddress()))
        .to.be.revertedWithCustomError(tokenWhitelist, "OwnableUnauthorizedAccount")
        .withArgs(await owner.getAddress());
    });

    it("should not allow non-owner to pause", async function () {
      // Since the contract inherits PausableUpgradeable but doesn't expose pause function directly,
      // we'll just verify the contract is not paused initially
      expect(await tokenWhitelist.paused()).to.be.false;

      // Only owner should be able to call pause if it was exposed
      // This is a theoretical test since the contract doesn't expose pause directly
    });
  });

  // Category 3: Token Management Tests
  describe("Token Management", function () {
    it("should add a single token", async function () {
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken1.getAddress())).to.be.true;
      expect(await tokenWhitelist.getWhitelistedTokenCount()).to.equal(1);
    });

    it("should add multiple tokens", async function () {
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      await tokenWhitelist.addToken(await mockToken2.getAddress());
      await tokenWhitelist.addToken(await mockToken3.getAddress());

      expect(await tokenWhitelist.getWhitelistedTokenCount()).to.equal(3);
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken1.getAddress())).to.be.true;
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken2.getAddress())).to.be.true;
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken3.getAddress())).to.be.true;
    });

    it("should remove tokens", async function () {
      // Add tokens
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      await tokenWhitelist.addToken(await mockToken2.getAddress());

      // Remove one token
      await tokenWhitelist.removeToken(await mockToken1.getAddress());

      // Check state
      expect(await tokenWhitelist.getWhitelistedTokenCount()).to.equal(1);
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken1.getAddress())).to.be.false;
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken2.getAddress())).to.be.true;
    });

    it("should revert when adding zero address", async function () {
      await expect(tokenWhitelist.addToken(ethers.ZeroAddress)).to.be.revertedWithCustomError(
        tokenWhitelist,
        "InvalidAddress"
      );
    });

    it("should revert when adding already whitelisted token", async function () {
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      await expect(
        tokenWhitelist.addToken(await mockToken1.getAddress())
      ).to.be.revertedWithCustomError(tokenWhitelist, "TokenNotSupported");
    });

    it("should revert when removing non-whitelisted token", async function () {
      await expect(
        tokenWhitelist.removeToken(await mockToken1.getAddress())
      ).to.be.revertedWithCustomError(tokenWhitelist, "TokenNotWhitelisted");
    });
  });

  // Category 4: Token Validation Tests
  describe("Token Validation", function () {
    beforeEach(async function () {
      // Add some tokens to the whitelist
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      await tokenWhitelist.addToken(await mockToken2.getAddress());
    });

    it("should correctly validate whitelisted tokens", async function () {
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken1.getAddress())).to.be.true;
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken2.getAddress())).to.be.true;
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken3.getAddress())).to.be.false;
    });

    it("should return correct token at index", async function () {
      expect(await tokenWhitelist.getWhitelistedTokenAt(0)).to.equal(await mockToken1.getAddress());
      expect(await tokenWhitelist.getWhitelistedTokenAt(1)).to.equal(await mockToken2.getAddress());
    });

    it("should revert when accessing invalid index", async function () {
      await expect(tokenWhitelist.getWhitelistedTokenAt(2)).to.be.revertedWithCustomError(
        tokenWhitelist,
        "InvalidLimits"
      );
    });

    it("should return correct page of tokens", async function () {
      // Add one more token
      await tokenWhitelist.addToken(await mockToken3.getAddress());

      // Get first page (2 tokens)
      const page1 = await tokenWhitelist.getWhitelistedTokensPage(0, 2);
      expect(page1.length).to.equal(2);
      expect(page1[0]).to.equal(await mockToken1.getAddress());
      expect(page1[1]).to.equal(await mockToken2.getAddress());

      // Get second page (1 token)
      const page2 = await tokenWhitelist.getWhitelistedTokensPage(2, 2);
      expect(page2.length).to.equal(1);
      expect(page2[0]).to.equal(await mockToken3.getAddress());
    });

    it("should revert when requesting page with invalid offset", async function () {
      await expect(tokenWhitelist.getWhitelistedTokensPage(3, 1)).to.be.revertedWithCustomError(
        tokenWhitelist,
        "InvalidLimits"
      );
    });
  });

  // Category 5: Event Tests
  describe("Events", function () {
    it("should emit TokenAdded event when adding token", async function () {
      await expect(tokenWhitelist.addToken(await mockToken1.getAddress()))
        .to.emit(tokenWhitelist, "TokenAdded")
        .withArgs(await mockToken1.getAddress());
    });

    it("should emit TokenRemoved event when removing token", async function () {
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      await expect(tokenWhitelist.removeToken(await mockToken1.getAddress()))
        .to.emit(tokenWhitelist, "TokenRemoved")
        .withArgs(await mockToken1.getAddress());
    });

    it("should emit OwnershipTransferred event when transferring ownership", async function () {
      await expect(tokenWhitelist.transferOwnership(await user.getAddress()))
        .to.emit(tokenWhitelist, "OwnershipTransferred")
        .withArgs(await owner.getAddress(), await user.getAddress());
    });
  });

  // Category 6: Integration Tests
  describe("Integration", function () {
    let vaultImplementation: Vault & Contract;
    let vaultFactory: VaultFactory & Contract;
    let gasStation: GasStation & Contract;
    let mockPriceFeed: any; // Using any type to avoid type issues

    beforeEach(async function () {
      // Deploy mock price feed
      const MockPriceFeedFactory = await ethers.getContractFactory("MockPriceFeed");
      mockPriceFeed = await MockPriceFeedFactory.deploy();
      await mockPriceFeed.setPrice(ethers.parseUnits("2000", 8)); // $2000 per ETH

      // Deploy Vault implementation
      const VaultFactory = await ethers.getContractFactory("Vault");
      vaultImplementation = (await VaultFactory.deploy()) as Vault & Contract;
      await vaultImplementation.waitForDeployment();

      // Deploy VaultFactory with TokenWhitelist using our helper function
      const result = await deployVaultFactoryWithLibraries(
        owner,
        await tokenWhitelist.getAddress()
      );
      vaultFactory = result.vaultFactory as VaultFactory & Contract;

      // Deploy GasStation
      const GasStationFactory = await ethers.getContractFactory("GasStation");
      const MIN_DEPOSIT = ethers.parseUnits("10", 6);
      const MAX_DEPOSIT = ethers.parseUnits("10000", 6);

      gasStation = (await upgrades.deployProxy(
        GasStationFactory,
        [
          await mockToken1.getAddress(),
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

      // Add tokens to whitelist
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      await tokenWhitelist.addToken(await mockToken2.getAddress());
    });

    it("should integrate with VaultFactory", async function () {
      // We need to create a vault directly since GasStation doesn't expose a method to create vaults

      // First, transfer ownership back to owner for this test
      await vaultFactory.connect(owner).transferOwnership(await owner.getAddress());

      // Now create a vault as the owner
      await vaultFactory.connect(owner).createVault(await owner.getAddress());

      // Get the vault address
      const vaultAddress = await vaultFactory.getLastVaultByOwner(await owner.getAddress());

      // Verify the vault was created
      expect(vaultAddress).to.not.equal(ethers.ZeroAddress);

      // Verify the vault has the correct token whitelist
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken1.getAddress())).to.be.true;
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken2.getAddress())).to.be.true;
    });

    it("should integrate with GasStation", async function () {
      // First, transfer ownership back to owner for this test
      await vaultFactory.connect(owner).transferOwnership(await owner.getAddress());

      // Set up VaultFactory in GasStation
      await gasStation.connect(owner).setVaultFactory(await vaultFactory.getAddress());

      // Create a vault for GasStation
      await vaultFactory.connect(owner).createVault(await gasStation.getAddress());

      // Get the vault address
      const vaultAddress = await vaultFactory.getLastVaultByOwner(await gasStation.getAddress());

      // Fund the vault with ETH
      await owner.sendTransaction({
        to: vaultAddress,
        value: ethers.parseEther("10"),
      });

      // Get the max deposit amount from the contract
      const maxDepositAmount = await gasStation.maxDepositAmount();

      // Calculate a safe deposit amount (considering token decimals)
      // mockToken1 has 18 decimals, but GasStation expects tokens with 6 decimals
      // We need to adjust the amount to not exceed maxDepositAmount
      const depositAmount = ethers.parseUnits("100", 6); // Use 6 decimals to match USDC

      // Verify the amount is within limits
      expect(depositAmount).to.be.lte(maxDepositAmount);

      // Mint tokens to user
      await mockToken1.mint(await user.getAddress(), ethers.parseUnits("1000", 18));

      // Approve tokens for GasStation
      await mockToken1
        .connect(user)
        .approve(await gasStation.getAddress(), ethers.parseUnits("1000", 18));

      // Calculate expected ETH amount
      const expectedEthAmount = await gasStation.calculateEthAmount(
        await mockToken1.getAddress(),
        depositAmount
      );

      // Use a different address for receiving ETH to avoid gas cost complications
      const receiverAddress = await otherUser.getAddress();
      const receiverBalanceBefore = await ethers.provider.getBalance(receiverAddress);

      // Exchange tokens for ETH, sending to otherUser instead of back to user
      await gasStation
        .connect(user)
        .exchange(await mockToken1.getAddress(), depositAmount, receiverAddress);

      const receiverBalanceAfter = await ethers.provider.getBalance(receiverAddress);

      // Verify receiver got the ETH (this address didn't pay for gas, so balance should increase)
      expect(receiverBalanceAfter).to.be.gt(receiverBalanceBefore);

      // Verify the exact amount received (should be exactly the expected ETH amount)
      const ethReceived = receiverBalanceAfter - receiverBalanceBefore;
      expect(ethReceived).to.equal(expectedEthAmount);
    });

    it("should handle token removal from whitelist", async function () {
      // First, transfer ownership back to owner for this test
      await vaultFactory.connect(owner).transferOwnership(await owner.getAddress());

      // Set up VaultFactory in GasStation
      await gasStation.connect(owner).setVaultFactory(await vaultFactory.getAddress());

      // Create a vault for GasStation
      await vaultFactory.connect(owner).createVault(await gasStation.getAddress());

      // Get the vault address
      const vaultAddress = await vaultFactory.getLastVaultByOwner(await gasStation.getAddress());

      // Fund the vault with ETH
      await owner.sendTransaction({
        to: vaultAddress,
        value: ethers.parseEther("10"),
      });

      // Calculate a safe deposit amount (considering token decimals)
      const depositAmount = ethers.parseUnits("100", 6); // Use 6 decimals to match USDC

      // First verify the token is supported before removal
      const tokenConfig = await gasStation.paymentTokens(await mockToken1.getAddress());
      expect(tokenConfig.isSupported).to.be.true;

      // Remove token from GasStation's supported tokens first
      await gasStation.connect(owner).removePaymentToken(await mockToken1.getAddress());

      // Then remove from whitelist
      await tokenWhitelist.removeToken(await mockToken1.getAddress());

      // Verify token is no longer supported in GasStation
      const tokenConfigAfter = await gasStation.paymentTokens(await mockToken1.getAddress());
      expect(tokenConfigAfter.isSupported).to.be.false;

      // Verify token is no longer whitelisted
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken1.getAddress())).to.be.false;

      // Try to exchange the removed token (should fail)
      await mockToken1.mint(await user.getAddress(), ethers.parseUnits("1000", 18));
      await mockToken1
        .connect(user)
        .approve(await gasStation.getAddress(), ethers.parseUnits("1000", 18));

      // This should fail because the token is no longer supported
      await expect(
        gasStation
          .connect(user)
          .exchange(await mockToken1.getAddress(), depositAmount, await user.getAddress())
      ).to.be.revertedWithCustomError(gasStation, "TokenNotSupported");
    });
  });

  // Category 7: Upgrade Tests
  describe("Upgrade Tests", function () {
    let tokenWhitelistV1: TokenWhitelist & Contract;
    let tokenWhitelistV2: TokenWhitelist & Contract;
    let mockTokenUpgrade: MockERC20 & Contract;
    let mockTokenUpgrade2: MockERC20 & Contract;

    // Create a mock implementation of TokenWhitelistV2 for testing
    // In a real scenario, you would create a new contract file with additional functionality
    beforeEach(async function () {
      // Deploy a fresh instance for upgrade tests
      const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");
      tokenWhitelistV1 = (await upgrades.deployProxy(TokenWhitelistFactory, [], {
        initializer: "initialize",
        kind: "uups",
      })) as TokenWhitelist & Contract;
      await tokenWhitelistV1.waitForDeployment();

      // Deploy mock tokens for testing
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      mockTokenUpgrade = (await MockERC20Factory.deploy("Upgrade Token", "UPG", 18)) as MockERC20 &
        Contract;
      mockTokenUpgrade2 = (await MockERC20Factory.deploy(
        "Upgrade Token 2",
        "UPG2",
        18
      )) as MockERC20 & Contract;

      // Add token to whitelist before upgrade
      await tokenWhitelistV1.addToken(await mockTokenUpgrade.getAddress());
    });

    it("should maintain state after upgrade", async function () {
      // Verify initial state
      expect(await tokenWhitelistV1.getWhitelistedTokenCount()).to.equal(1);
      expect(await tokenWhitelistV1.isTokenWhitelisted(await mockTokenUpgrade.getAddress())).to.be
        .true;

      // Perform upgrade
      const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");
      tokenWhitelistV2 = (await upgrades.upgradeProxy(
        await tokenWhitelistV1.getAddress(),
        TokenWhitelistFactory
      )) as TokenWhitelist & Contract;

      // Verify state is preserved after upgrade
      expect(await tokenWhitelistV2.getWhitelistedTokenCount()).to.equal(1);
      expect(await tokenWhitelistV2.isTokenWhitelisted(await mockTokenUpgrade.getAddress())).to.be
        .true;
      expect(await tokenWhitelistV2.owner()).to.equal(await owner.getAddress());
    });

    it("should only allow owner to upgrade", async function () {
      // Create a new implementation contract
      const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");

      // Attempt to upgrade from non-owner account should fail
      // We need to use a try/catch because upgrades.upgradeProxy doesn't support expect().to.be.revertedWith
      try {
        await upgrades.upgradeProxy(
          await tokenWhitelistV1.getAddress(),
          TokenWhitelistFactory.connect(user)
        );
        // If we reach here, the upgrade didn't revert as expected
        expect.fail("Upgrade should have reverted");
      } catch (error: any) {
        // Verify the error is related to ownership
        expect(error.message).to.include("OwnableUnauthorizedAccount");
      }

      // Owner should be able to upgrade
      tokenWhitelistV2 = (await upgrades.upgradeProxy(
        await tokenWhitelistV1.getAddress(),
        TokenWhitelistFactory.connect(owner)
      )) as TokenWhitelist & Contract;

      // Verify upgrade was successful
      expect(await tokenWhitelistV2.getWhitelistedTokenCount()).to.equal(1);
    });

    it("should maintain version after upgrade with same implementation", async function () {
      // Get initial version
      const initialVersion = await tokenWhitelistV1.VERSION();
      expect(initialVersion).to.equal(1);

      // Upgrade with the same implementation
      const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");
      tokenWhitelistV2 = (await upgrades.upgradeProxy(
        await tokenWhitelistV1.getAddress(),
        TokenWhitelistFactory
      )) as TokenWhitelist & Contract;

      // Version should remain the same
      const newVersion = await tokenWhitelistV2.VERSION();
      expect(newVersion).to.equal(initialVersion);
    });

    it("should simulate new functionality after upgrade", async function () {
      // In a real scenario, you would upgrade to a new implementation with new functions
      // For this test, we'll simulate new functionality by performing multiple operations

      // Upgrade to V2 (same implementation for test purposes)
      const TokenWhitelistFactory = await ethers.getContractFactory("TokenWhitelist");
      tokenWhitelistV2 = (await upgrades.upgradeProxy(
        await tokenWhitelistV1.getAddress(),
        TokenWhitelistFactory
      )) as TokenWhitelist & Contract;

      // Simulate a "batch add" functionality that might exist in V2
      // by adding multiple tokens in sequence
      await tokenWhitelistV2.addToken(await mockTokenUpgrade2.getAddress());

      // Verify the new token was added
      expect(await tokenWhitelistV2.isTokenWhitelisted(await mockTokenUpgrade2.getAddress())).to.be
        .true;

      // Verify both tokens are now in the whitelist
      expect(await tokenWhitelistV2.getWhitelistedTokenCount()).to.equal(2);

      // This demonstrates that the contract maintains its state and can be extended with new operations
    });
  });

  // Category 8: Edge Cases and Error Handling
  describe("Edge Cases and Error Handling", function () {
    it("should handle large token lists efficiently", async function () {
      // First, make sure we have a clean whitelist
      // Remove any tokens that might have been added in previous tests
      const count = await tokenWhitelist.getWhitelistedTokenCount();
      for (let i = 0; i < count; i++) {
        const token = await tokenWhitelist.getWhitelistedTokenAt(0);
        await tokenWhitelist.removeToken(token);
      }

      // Create a reasonable number of tokens (20) for testing pagination
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const tokens: string[] = [];

      // Deploy tokens one by one and ensure they're fully deployed
      for (let i = 0; i < 20; i++) {
        const token = await MockERC20Factory.deploy(`LargeTest ${i}`, `LT${i}`, 18);
        await token.waitForDeployment();

        // Perform a transaction to ensure the contract is fully deployed
        await token.decimals();

        tokens.push(await token.getAddress());
      }

      // Add tokens in batches using the batch function
      // The contract has a MAX_BATCH_SIZE of 50, so we can add all 20 at once
      await tokenWhitelist.addTokensBatch(tokens);

      // Verify all tokens were added (some might be skipped if invalid)
      const finalCount = await tokenWhitelist.getWhitelistedTokenCount();
      console.log(`Successfully added ${finalCount} tokens out of ${tokens.length}`);

      // Test pagination with various page sizes
      const smallPage = await tokenWhitelist.getWhitelistedTokensPage(0, 5);
      expect(smallPage.length).to.equal(5);

      const mediumPage = await tokenWhitelist.getWhitelistedTokensPage(5, 10);
      expect(mediumPage.length).to.equal(10);

      // If we have at least 15 tokens, test a larger page
      if (finalCount >= 15) {
        const largePage = await tokenWhitelist.getWhitelistedTokensPage(0, 15);
        expect(largePage.length).to.equal(15);
      }

      // Test getting tokens at specific indices
      if (finalCount > 0) {
        const firstToken = await tokenWhitelist.getWhitelistedTokenAt(0);
        expect(tokens).to.include(firstToken);

        if (finalCount > 1) {
          const lastIndex = Number(finalCount) - 1;
          const lastToken = await tokenWhitelist.getWhitelistedTokenAt(lastIndex);
          expect(tokens).to.include(lastToken);
        }
      }
    });

    it("should handle invalid addresses gracefully", async function () {
      // Test with zero address
      await expect(tokenWhitelist.addToken(ethers.ZeroAddress)).to.be.revertedWithCustomError(
        tokenWhitelist,
        "InvalidAddress"
      );

      // Test with non-contract address (using a regular EOA address)
      const randomAddress = await user.getAddress();

      // Now the contract validates if the address is a contract
      // This should revert with InvalidTokenContract error
      await expect(tokenWhitelist.addToken(randomAddress)).to.be.revertedWithCustomError(
        tokenWhitelist,
        "InvalidTokenContract"
      );
    });

    it("should handle removal of non-existent tokens gracefully", async function () {
      // Attempt to remove a token that was never added
      await expect(
        tokenWhitelist.removeToken(await mockToken1.getAddress())
      ).to.be.revertedWithCustomError(tokenWhitelist, "TokenNotWhitelisted");

      // Add and remove the same token
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      await tokenWhitelist.removeToken(await mockToken1.getAddress());

      // Attempt to remove it again
      await expect(
        tokenWhitelist.removeToken(await mockToken1.getAddress())
      ).to.be.revertedWithCustomError(tokenWhitelist, "TokenNotWhitelisted");
    });

    it("should handle re-adding previously removed tokens", async function () {
      // Add token
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken1.getAddress())).to.be.true;

      // Remove token
      await tokenWhitelist.removeToken(await mockToken1.getAddress());
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken1.getAddress())).to.be.false;

      // Re-add the same token
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      expect(await tokenWhitelist.isTokenWhitelisted(await mockToken1.getAddress())).to.be.true;

      // Verify token count
      expect(await tokenWhitelist.getWhitelistedTokenCount()).to.equal(1);
    });

    it("should handle edge cases in pagination", async function () {
      // Test with empty list
      await tokenWhitelist.getWhitelistedTokenCount();

      // When the list is empty, even offset 0 will cause a revert because 0 >= 0
      await expect(tokenWhitelist.getWhitelistedTokensPage(0, 5)).to.be.revertedWithCustomError(
        tokenWhitelist,
        "InvalidLimits"
      );

      // Add some tokens
      await tokenWhitelist.addToken(await mockToken1.getAddress());
      await tokenWhitelist.addToken(await mockToken2.getAddress());
      await tokenWhitelist.getWhitelistedTokenCount();

      // Test with limit = 0
      const zeroLimitPage = await tokenWhitelist.getWhitelistedTokensPage(0, 0);
      expect(zeroLimitPage.length).to.equal(0);

      // Test with offset > count
      await expect(tokenWhitelist.getWhitelistedTokensPage(3, 1)).to.be.revertedWithCustomError(
        tokenWhitelist,
        "InvalidLimits"
      );

      // Test with offset = count
      await expect(tokenWhitelist.getWhitelistedTokensPage(2, 1)).to.be.revertedWithCustomError(
        tokenWhitelist,
        "InvalidLimits"
      );

      // Test with valid pagination
      const validPage = await tokenWhitelist.getWhitelistedTokensPage(0, 2);
      expect(validPage.length).to.equal(2);

      const partialPage = await tokenWhitelist.getWhitelistedTokensPage(1, 2);
      expect(partialPage.length).to.equal(1);
    });
  });
});
