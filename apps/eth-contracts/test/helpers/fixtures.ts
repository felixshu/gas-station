import { ethers, upgrades } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { Contract } from "ethers";
import { VaultFactory } from "../../typechain-types";

/**
 * Deploy VaultFactory with internal libraries
 * @notice This function deploys the VaultFactory contract which now uses internal libraries
 * instead of external libraries, so no library linking is required.
 */
export async function deployVaultFactoryWithLibraries(
  owner: HardhatEthersSigner,
  tokenWhitelistAddress: string
) {
  // Deploy Vault implementation
  const VaultImpl = await ethers.getContractFactory("Vault");
  const vaultImplementation = await VaultImpl.deploy();
  await vaultImplementation.waitForDeployment();

  // Deploy VaultFactory (now with internal libraries)
  const VaultFactoryFactory = await ethers.getContractFactory("VaultFactory", {
    signer: owner,
  });

  // Use the upgrades plugin to deploy the VaultFactory as a proxy
  const vaultFactory = (await upgrades.deployProxy(
    VaultFactoryFactory,
    [await vaultImplementation.getAddress(), tokenWhitelistAddress],
    {
      initializer: "initialize",
    }
  )) as VaultFactory & Contract;

  await vaultFactory.waitForDeployment();

  return {
    vaultFactory,
    vaultImplementation,
  };
}
