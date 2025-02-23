import { ethers, upgrades } from 'hardhat';
import type { ContractFactory, Contract } from 'ethers';
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers';

async function deployContract<T extends Contract>(
  name: string,
  factory: ContractFactory,
  deployer: HardhatEthersSigner,
  ...args: unknown[]
): Promise<T> {
  console.log(`Deploying ${name}...`);
  const contract = await factory.connect(deployer).deploy(...args);
  await contract.waitForDeployment();
  console.log(`${name} deployed to:`, await contract.getAddress());
  return contract as T;
}

async function deployProxy<T extends Contract>(
  name: string,
  factory: ContractFactory,
  args: unknown[] = []
): Promise<T> {
  console.log(`Deploying ${name}...`);
  const contract = await upgrades.deployProxy(factory, args, {
    initializer: 'initialize',
  });
  await contract.waitForDeployment();
  console.log(`${name} deployed to:`, await contract.getAddress());
  return contract as T;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log('Deploying contracts with the account:', deployer.address);

  try {
    // Deploy TokenWhitelist
    const TokenWhitelist = await ethers.getContractFactory('TokenWhitelist');
    const tokenWhitelist = await deployProxy('TokenWhitelist', TokenWhitelist);

    // Deploy Vault Implementation
    const Vault = await ethers.getContractFactory('Vault');
    const vaultImplementation = await deployContract(
      'Vault Implementation',
      Vault,
      deployer
    );

    // Deploy VaultFactory
    const VaultFactory = await ethers.getContractFactory('VaultFactory');
    const vaultFactory = await deployProxy('VaultFactory', VaultFactory, [
      await vaultImplementation.getAddress(),
      await tokenWhitelist.getAddress(),
    ]);

    // Deploy GasStation
    const GasStation = await ethers.getContractFactory('GasStation');

    // TODO: Replace these values with actual configuration
    const defaultToken = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'; // USDC on mainnet
    const defaultPriceFeed = '0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6'; // USDC/ETH price feed
    const minDepositAmount = ethers.parseUnits('100', 6); // 100 USDC minimum
    const maxDepositAmount = ethers.parseUnits('5000', 6); // 5000 USDC maximum

    const gasStation = await deployProxy('GasStation', GasStation, [
      defaultToken,
      defaultPriceFeed,
      minDepositAmount,
      maxDepositAmount,
      await vaultFactory.getAddress(),
    ]);

    // Print deployment summary
    console.log('\nDeployment Summary:');
    console.log('-------------------');
    console.log('TokenWhitelist:', await tokenWhitelist.getAddress());
    console.log(
      'Vault Implementation:',
      await vaultImplementation.getAddress()
    );
    console.log('VaultFactory:', await vaultFactory.getAddress());
    console.log('GasStation:', await gasStation.getAddress());

    // Save deployment addresses
    const deployments = {
      tokenWhitelist: await tokenWhitelist.getAddress(),
      vaultImplementation: await vaultImplementation.getAddress(),
      vaultFactory: await vaultFactory.getAddress(),
      gasStation: await gasStation.getAddress(),
      network: (await ethers.provider.getNetwork()).name,
      deployer: deployer.address,
    };

    console.log('\nDeployment saved successfully');
    return deployments;
  } catch (error) {
    console.error('Deployment failed:', error);
    throw error;
  }
}

main()
  .then(() => {
    console.log('\nAll deployments completed successfully');
    process.exit(0);
  })
  .catch((error) => {
    console.error('\nDeployment failed:', error);
    process.exit(1);
  });
