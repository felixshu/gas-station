import { ethers } from "hardhat";

async function main() {
  console.log("Deploying libraries...");

  // Deploy VaultUtils library
  const VaultUtils = await ethers.getContractFactory("VaultUtils");
  const vaultUtils = await VaultUtils.deploy();
  await vaultUtils.waitForDeployment();
  console.log(`VaultUtils deployed to: ${await vaultUtils.getAddress()}`);

  // Deploy VaultBalancer library
  const VaultBalancer = await ethers.getContractFactory("VaultBalancer");
  const vaultBalancer = await VaultBalancer.deploy();
  await vaultBalancer.waitForDeployment();
  console.log(`VaultBalancer deployed to: ${await vaultBalancer.getAddress()}`);

  console.log("Libraries deployed successfully");

  return {
    vaultUtils: await vaultUtils.getAddress(),
    vaultBalancer: await vaultBalancer.getAddress(),
  };
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

export default main;
