require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-chai-matchers");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.16",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      // The verified Biswap modules are close to the EIP-170 limit. The local
      // test network does not need the mainnet size restriction.
      allowUnlimitedContractSize: true,
      // Hardhat's built-in chain list does not include BSC. Tell EDR which
      // hardfork was active at the forked block so historical execution works.
      chains: {
        56: {
          hardforkHistory: {
            shanghai: 0,
          },
        },
      },
    },
  },
};
