import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-gas-reporter"
import "dotenv/config"
import "@openzeppelin/hardhat-upgrades";

const config: HardhatUserConfig = {
  solidity: "0.8.17", 
  gasReporter: {
    enabled: (process.env.REPORT_GAS) ? true : false,
    coinmarketcap: process.env.CMC_KEY,
    currency: 'USD'
  },
  networks: {
    hardhat: {
      chainId: 1337
    }
  }
};

export default config;
