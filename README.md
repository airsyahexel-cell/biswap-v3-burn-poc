# Biswap V3 `burn()` Rounding Bug — Post-Mortem & PoC

![tests](https://github.com/airsyahexel-cell/biswap-v3-burn-poc/actions/workflows/test.yml/badge.svg)
![Solidity](https://img.shields.io/badge/Solidity-0.8.16-363636)
![Hardhat](https://img.shields.io/badge/Hardhat-2.22-yellow)
![License](https://img.shields.io/badge/license-MIT%20%2B%20BUSL--1.1-blue)

**A liquidity-accounting bug that let an attacker mint 4.847B phantom liquidity, burn it to zero, and buy 11,283 WBNB for 63,263 wei of BUSD.**

On **24 November 2026**, a legacy Biswap V3 WBNB/BUSD pool on BNB Chain was drained of **50,993.9789 BUSD** gross. After repaying a Pancake V3 flash loan, the attacker walked away with **50,553.9228 BUSD** (≈ $50.55K). The root cause is a single conditional in `LiquidityModule.burn()`: the pool only decreases its active liquidity when the *rounded* current-point amounts are non-zero. At the bottom of the price range, those amounts round to zero even though the position is active.

This repository is an independent, defensive reconstruction. It contains:

- the exact verified Biswap V3 pool and module sources,
- a deterministic local reproduction with mock tokens,
- a fixed `LiquidityModule` and a regression test,
- an optional end-to-end test against real BSC state at block `135526419`,
- a detailed post-mortem and fix rationale.

> **Disclaimer:** This is security research and educational material. The attack contract is intended for local tests and forked state only. Do not use it against live contracts you do not own or have permission to test. The authors are not responsible for misuse.

---

## TL;DR

| Item | Value |
|---|---|
| Chain | BNB Smart Chain (BSC) |
| Incident time | 2026-11-24 20:24:58 UTC |
| Exploit block | `135526420` |
| Exploit tx | [`0x13b8310513cc7ff91ad24a966f6ced99aa535d2aef8a231e38737401c8e7f78c`](https://bscscan.com/tx/0x13b8310513cc7ff91ad24a966f6ced99aa535d2aef8a231e38737401c8e7f78c) |
| Victim pool | [`0xc83f96f87f586a858a14c89e16434460bac0b643`](https://bscscan.com/address/0xc83f96f87f586a858a14c89e16434460bac0b643) (WBNB/BUSD, fee 800, pointDelta 5) |
| Attacker EOA | [`0x1ec9d79d1a7c47c3887d8fc322c88e56b16e90a5`](https://bscscan.com/address/0x1ec9d79d1a7c47c3887d8fc322c88e56b16e90a5) |
| Attack contract | [`0x6161a9ca16f213c3373c07bcc0c4b4a4705340be`](https://bscscan.com/address/0x6161a9ca16f213c3373c07bcc0c4b4a4705340be) |
| Flash loan | 11,283 WBNB from Pancake V3 |
| Gross BUSD removed from pool | **50,993.978909612723523404 BUSD** |
| Net attacker profit | **50,553.92284109438 BUSD** |
| Phantom liquidity left in pool | **4,847,000,000** |
| Pool after attack | 0.009999999836223139 WBNB, 81.501165597941276329 BUSD |

---

## 1. Background: Biswap V3 / iZiSwap accounting

Biswap V3 is an iZiSwap-style concentrated-liquidity AMM. Prices are discretized into **points**:

```text
price = 1.0001 ^ point
```

The victim pool used `pointDelta = 5`, so initialized ranges and endpoints are aligned to multiples of 5. At the pool level, `state` tracks:

```solidity
struct State {
    uint160 sqrtPrice_96;
    int24   currentPoint;
    uint16  observationCurrentIndex;
    uint16  observationQueueLen;
    uint16  observationNextQueueLen;
    bool    locked;
    uint240 feeTimesL;
    uint16  fee;
    uint128 liquidity;   // active liquidity at currentPoint
    uint128 liquidityX;  // part of active liquidity held in tokenX
}
```

A liquidity position is keyed by `(owner, leftPt, rightPt)` and stores its own `liquidity`, fee debt, and owed tokens. `mint()` adds liquidity and updates the active state if the new range contains the current point. `burn()` removes liquidity and should do the mirror-image update.

The critical helper is `_computeWithdrawXY()`. It returns:

- `x`, `y`: total token amounts owed for the burned liquidity,
- `xc`, `yc`: the parts of that position that sit exactly at the current point,
- `liquidityX`: the new active `liquidityX` if the range is active.

For a position that contains the current point, `xc` and `yc` are the amounts attributable to the current point. For a position entirely below or above the current point, one of them is the whole amount and the other is zero. At extreme points and tiny positions, **both can round down to zero**.

---

## 2. Root cause

The vulnerable code is in `LiquidityModule.burn()` (verified source at `contracts/biswap/core/liquidity.sol`):

```solidity
// compute amount of tokenX and tokenY should be paid from minter
WithdrawRet memory withRet = _computeWithdrawXY(
    liquidDelta,
    leftPt,
    rightPt,
    currentState
);

// update state
Liquidity.Data storage lq = liquidity.get(msg.sender, leftPt, rightPt);

if (withRet.yc > 0 || withRet.xc > 0) {
    state.liquidity = curLiquidity - liquidDelta;
    state.liquidityX = withRet.liquidityX;
    state.feeTimesL -= liquidDelta * lq.feeVote;
    state.fee = state.liquidity == 0
        ? fee
        : normalizeFeeInRange(fee, uint16(state.feeTimesL / state.liquidity));
}
if (withRet.x > 0 || withRet.y > 0) {
    lq.tokenOwedX += withRet.x;
    lq.tokenOwedY += withRet.y;
}
```

The guard on line 485 is wrong. It uses the **rounded current-point amounts** as a proxy for "is this range active?" The correct question is:

> Does `[leftPt, rightPt)` contain `currentPoint`?

When the range is active but `yc == 0 && xc == 0`, the code:

1. removes `liquidDelta` from the position via `_updateLiquidity()`,
2. credits the below/above-current-point amounts to `tokenOwedX/Y`,
3. **skips** the pool-level `state.liquidity` and `state.liquidityX` update.

The position is gone, but the pool still reports the old active liquidity. That is phantom liquidity.

### Why `yc` and `xc` both round to zero

The attacker pushed the pool to point `-400001`, near the bottom of the allowed range (`leftMostPt = -800000`). At that point:

- `sqrtPrice ≈ 4.25e-18`,
- the position `[-400050, -400000)` is active,
- minting `4,847,000,000` liquidity costs only **500 wei BUSD**,
- each `burn` of `484,700,000` liquidity returns **48 wei BUSD** (the part below the current point),
- the current-point components `yc` and `xc` are both **0** because the position's token amounts at the current point are far below 1 wei.

So the burn is economically meaningful for the position (it reduces the position's liquidity), but the pool-level active-liquidity branch is skipped.

### The phantom-liquidity loop

| Step | Position liquidity | `state.liquidity` | `amountX` | `amountY` |
|---|---:|---:|---:|---:|
| Mint | 4,847,000,000 | 4,847,000,000 | 0 | 500 |
| Burn 1 | 4,362,300,000 | 4,847,000,000 | 0 | 48 |
| Burn 2 | 3,877,600,000 | 4,847,000,000 | 0 | 48 |
| Burn 3 | 3,392,900,000 | 4,847,000,000 | 0 | 48 |
| Burn 4 | 2,908,200,000 | 4,847,000,000 | 0 | 48 |
| Burn 5 | 2,423,500,000 | 4,847,000,000 | 0 | 48 |
| Burn 6 | 1,938,800,000 | 4,847,000,000 | 0 | 48 |
| Burn 7 | 1,454,100,000 | 4,847,000,000 | 0 | 48 |
| Burn 8 | 969,400,000 | 4,847,000,000 | 0 | 48 |
| Burn 9 | 484,700,000 | 4,847,000,000 | 0 | 48 |
| Burn 10 | 0 | **4,847,000,000** | 0 | 48 |

After ten burns, the position is empty but the pool still believes `4,847,000,000` liquidity is active. The attacker collects `480` wei BUSD, then swaps a negligible amount of BUSD against the phantom liquidity.

---

## 3. Attack flow

```text
┌─────────────────────────────────────────────────────────────────────┐
│ 1. Flash loan 11,283 WBNB from Pancake V3                           │
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. swapX2Y(cap = 11,283 WBNB, lowPt = -400001)                      │
│    Consumes 11,282.950792773071452601 WBNB                          │
│    Returns 50,993.978909612723586687 BUSD                           │
│    Pool price: 224000 → -400001, active liquidity: 0                │
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. mint([-400050, -400000), 4,847,000,000 liquidity)                │
│    Cost: 500 wei BUSD                                               │
│    state.liquidity = 4,847,000,000                                  │
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. burn(484,700,000) × 10                                           │
│    Each burn: position -= 484,700,000; amountY = 48 wei             │
│    state.liquidity stays 4,847,000,000 (BUG)                        │
│    After 10 burns: position = 0, state.liquidity = 4,847,000,000    │
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. collect(0, max)                                                  │
│    Receives 480 wei BUSD                                            │
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 6. swapY2XDesireX(desireX = 11,283.277957284066035619 WBNB)          │
│    Pays 63,263 wei BUSD                                             │
│    Receives 11,283.277957284066035619 WBNB                          │
│    Pool price: -400001 → -394508                                    │
│    state.liquidity remains 4,847,000,000                            │
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 7. Repay flash loan: 11,284.1283 WBNB                               │
│    Shortfall covered by swapping 440.0560685183417 BUSD → WBNB      │
│    Net profit: 50,553.92284109438 BUSD                              │
└─────────────────────────────────────────────────────────────────────┘
```

### Why the drain swap works

After the ten burns, the pool's active liquidity is `4,847,000,000`, but there is no position backing it. `swapY2XDesireX` walks the price upward and treats that phantom liquidity as real. The pool pays out tokenX (WBNB) from its reserves. The attacker only needs to pay `63,263` wei BUSD because the desired WBNB output is priced against the phantom liquidity.

The pool's WBNB reserves are not "free" in a normal AMM: they belong to positions above the current price. The phantom liquidity lets the attacker buy those reserves at a price that ignores the real liquidity distribution.

---

## 4. Reproduction

### 4.1 Local deterministic test

The local test uses the **exact verified pool and liquidity-module sources** with mock ERC-20 tokens and a minimal mock factory. It starts from the post-crash reserves reconstructed from BSC state, so it isolates the burn bug without replaying the first swap.

```bash
npm install
npm test
```

Expected output:

```text
  Biswap V3 burn rounding — phantom liquidity
    phantom liquidity left in pool: 4847000000
    tokenX drained: 11283.277957284066035619
    net tokenY paid (wei): 63283
    ✔ leaves active liquidity untouched and drains tokenX (1981ms)
    ✔ fixed module decrements active liquidity and blocks the drain (7729ms)

  2 passing (10s)
```

The first test asserts that:

- the position's liquidity goes to zero after ten burns,
- `state.liquidity` remains `4,847,000,000` after every burn,
- the attacker collects `480` wei BUSD,
- the final swap pays `63,263` wei BUSD and receives `11,283.277957284066035619` WBNB,
- the pool is left with `4,847,000,000` phantom liquidity.

The second test swaps in `LiquidityModuleFixed` and asserts that:

- `state.liquidity` decreases by `484,700,000` on every burn,
- after ten burns, `state.liquidity == 0`,
- the drain swap reverts,
- the attacker receives no WBNB.

### 4.2 Optional end-to-end fork test

The fork test runs against the **real BSC contracts** at block `135526419`, the block before the exploit. It wraps BNB into WBNB, replays the price-crashing swap with the same `11,283 WBNB` cap, then executes the mint/burn/collect/drain sequence.

Requirements:

- an archive-capable BSC RPC endpoint (the free Alchemy BSC endpoint works),
- `BSC_RPC_URL` set in the environment.

```bash
# PowerShell
$env:BSC_RPC_URL="https://bnb-mainnet.g.alchemy.com/v2/<YOUR_KEY>"
npx hardhat test test/BiswapV3Burn.fork.test.js
```

Expected output:

```text
  Biswap V3 fork reproduction
    real pool BUSD removed: 50993.978909612723523404
    real pool WBNB after:   0.009999999836223139
    phantom liquidity:      4847000000
    attacker WBNB:          11300.327164510994583018
    attacker BUSD:          50993.978909612723523404
    ✔ reproduces the on-chain drain against the real pool (855ms)

  1 passing (6s)
```

The fork test asserts exact on-chain values:

- first swap consumes `11,282.950792773071452601` WBNB and returns `50,993.978909612723586687` BUSD,
- after the crash: `currentPoint = -400001`, `liquidity = 0`,
- after the attack: `currentPoint = -394508`, `liquidity = 4,847,000,000`, `liquidityX = 2,896,494,600`,
- pool WBNB = `9,999,999,836,223,139` wei,
- pool BUSD = `81,501,165,597,941,276,329` wei,
- the attacker's position is empty while the pool's active liquidity is still `4,847,000,000`.

> The fork test keeps the flash-loan principal inside the attack contract, so its `attacker WBNB` balance is `11,300.3271...`, not the on-chain post-repayment balance. The net profit after repaying `11,284.1283 WBNB` and swapping `440.0561 BUSD` for the shortfall is `50,553.9228 BUSD`.

---

## 5. The fix

The correct condition is whether the burned range is active, not whether the rounded current-point amounts are non-zero.

```diff
- if (withRet.yc > 0 || withRet.xc > 0) {
+ if (leftPt <= currentState.currentPoint && rightPt > currentState.currentPoint) {
      state.liquidity = curLiquidity - liquidDelta;
      state.liquidityX = withRet.liquidityX;
      state.feeTimesL -= liquidDelta * lq.feeVote;
      state.fee = state.liquidity == 0
          ? fee
          : normalizeFeeInRange(fee, uint16(state.feeTimesL / state.liquidity));
  }
```

Why this is correct:

- If `currentPoint` is inside `[leftPt, rightPt)`, the burned liquidity is part of `state.liquidity` and must be subtracted, regardless of rounding.
- If the range is entirely below or above `currentPoint`, the burned liquidity is not part of `state.liquidity` and must not be subtracted.
- `state.liquidityX` must be refreshed for active burns so the tokenX/tokenY split stays consistent.
- The `feeTimesL` and `fee` updates belong with the active-liquidity update; they should not be skipped for tiny active burns.

The fixed module is in `contracts/fixed/LiquidityModuleFixed.sol`. The regression test deploys it through the same mock factory and verifies that the drain is blocked.

### Additional hardening

1. **Invariant:** for every active position, the sum of position liquidity should equal `state.liquidity` (up to positions that are exactly at the current point and the `liquidityX` split). Add a fuzz/invariant test that mints and burns random ranges around the current point, including extreme points and 1-wei amounts.
2. **Underflow guard:** add `require(curLiquidity >= liquidDelta, "LIQ")` before subtracting. This turns any future accounting drift into a revert instead of a silent underflow (Solidity 0.8 already reverts, but an explicit check documents the invariant).
3. **Event monitoring:** alert on `Burn` events where the position's liquidity decreases but `state.liquidity` does not. The on-chain logs show exactly this pattern ten times in one transaction.
4. **Fork review:** audit all delegatecall modules for guards that use "amount > 0" as a proxy for "state changed". The same anti-pattern can hide in swap, collect, or limit-order paths.

---

## 6. Impact

- **Direct loss:** 50,993.9789 BUSD removed from the pool; 50,553.9228 BUSD net profit to the attacker.
- **LP loss:** the pool's remaining BUSD was `81.5012`, and its WBNB was `0.01`. Liquidity providers in the affected pool lost the assets that the phantom liquidity bought.
- **Accounting integrity:** `state.liquidity` is a core input to swaps, fee growth, and oracle/price logic. Leaving it stale breaks all of them, not just the drained pool.
- **Composability risk:** protocols that quote or price against `state.liquidity` could misprice assets or accept bad collateral while the phantom liquidity persists.

The bug is **not** a generic Uniswap V3 bug. It is specific to the Biswap/iZiSwap `burn()` implementation's conditional state update. Forks that copied the pattern are potentially affected and should check their own `burn()` logic.

---

## 7. Timeline (exploit transaction)

All events are in block `135526420`, transaction `0x13b831...f78c`:

| Time (UTC) | Event |
|---|---|
| 20:24:58 | Flash loan 11,283 WBNB from Pancake V3 |
| 20:24:58 | `swapX2Y` crashes the pool to point `-400001`; active liquidity becomes 0 |
| 20:24:58 | `mint` 4,847,000,000 liquidity for 500 wei BUSD |
| 20:24:58 | Ten `burn` calls of 484,700,000 each; `state.liquidity` stays 4,847,000,000 |
| 20:24:58 | `collect` 480 wei BUSD |
| 20:24:58 | `swapY2XDesireX` buys 11,283.277957284066035619 WBNB for 63,263 wei BUSD |
| 20:24:58 | Flash loan repaid; 440.0561 BUSD swapped for the WBNB shortfall |
| After | Pool left with 0.009999999836223139 WBNB and 81.501165597941276329 BUSD |

This repository is an independent reconstruction. It does not claim to represent an official Biswap post-mortem.

---

## 8. Repository layout

```text
.
├── contracts/
│   ├── AttackBiswapBurn.sol          # reproduction harness (MIT)
│   ├── biswap/                       # verified Biswap V3 sources (BUSL-1.1)
│   │   ├── core/BiswapPoolV3.sol
│   │   ├── core/liquidity.sol        # vulnerable burn()
│   │   ├── core/swapY2X.sol
│   │   ├── interfaces/
│   │   └── libraries/
│   ├── fixed/
│   │   └── LiquidityModuleFixed.sol  # patched module (BUSL-1.1 derivative)
│   └── mocks/
│       ├── MockERC20.sol
│       └── MockBiswapFactory.sol
├── test/
│   ├── BiswapV3Burn.test.js          # local vulnerable vs fixed tests
│   └── BiswapV3Burn.fork.test.js     # optional real-BSC fork test
├── scripts/
│   └── fork-check.js                 # manual fork diagnostic
├── LICENSES/
│   └── BUSL-1.1.txt
├── NOTICE.md
├── LICENSE
├── hardhat.config.js
├── package.json
└── README.md
```

### Verified source provenance

The files under `contracts/biswap/` are the verified sources of the victim pool and its modules, retrieved from Sourcify:

- Pool: [`0xc83f96f87f586a858a14c89e16434460bac0b643`](https://sourcify.dev/#/lookup/0xc83f96f87f586a858a14c89e16434460bac0b643)
- Liquidity module: [`0xcbc519bbd6e48061641ac2c332d050fc673e44a1`](https://sourcify.dev/#/lookup/0xcbc519bbd6e48061641ac2c332d050fc673e44a1)
- SwapY2X module: [`0xec76a8f55cdfae41fa5cd4e7778be70aca7d89b2`](https://sourcify.dev/#/lookup/0xec76a8f55cdfae41fa5cd4e7778be70aca7d89b2)
- Factory: [`0x7c3d53606f9c03e7f54abddffc3868e1c5466863`](https://sourcify.dev/#/lookup/0x7c3d53606f9c03e7f54abddffc3868e1c5466863)

The pool's module wiring from `factory.addresses()`:

| Module | Address |
|---|---|
| swapX2Y | `0x32694a9908c74cfe13be56bff181bd2578c325d2` |
| swapY2X | `0xec76a8f55cdfae41fa5cd4e7778be70aca7d89b2` |
| liquidity | `0xcbc519bbd6e48061641ac2c332d050fc673e44a1` |
| limitOrder | `0x36b425f04ae1f5242df22f3a560bcfab40451cdc` |
| flash | `0x5af171610859ccc643f2cc7459f7b904c11dadfe` |

---

## 9. References

- Exploit transaction: <https://bscscan.com/tx/0x13b8310513cc7ff91ad24a966f6ced99aa535d2aef8a231e38737401c8e7f78c>
- Victim pool: <https://bscscan.com/address/0xc83f96f87f586a858a14c89e16434460bac0b643>
- Smart Contract Shacking — Biswap V3 hack: <https://smartcontractshacking.com/hacks/biswap-v3-hack-2026>
- Blockchain Breaches — Biswap 2026: <https://www.blockchainbreaches.com/en/breaches/biswap-2026>
- Panda Security — Biswap V3 exploit write-up: <https://dev.to/pandasecurity/biswap-v3-exploit-burn-bug-drains-50554-busd-51b3>
- Uniswap V3 whitepaper: <https://uniswap.org/whitepaper-v3.pdf>
- iZiSwap documentation: <https://docs.izumi.finance/>

---

## 10. License

- Original code in this repository (attack harness, mocks, tests, scripts, documentation) is licensed under the **MIT License**. See `LICENSE`.
- The verified Biswap V3 sources under `contracts/biswap/` and the derivative `contracts/fixed/LiquidityModuleFixed.sol` are licensed under **BUSL-1.1** (SPDX headers preserved). See `NOTICE.md` and `LICENSES/BUSL-1.1.txt`.

---

## 11. Disclaimer

This repository is provided **as-is**, for educational and defensive security research only. It is not financial advice, not an endorsement of any exploit, and not a guarantee that the fix is complete. Always obtain independent audits before deploying financial contracts. The authors are not responsible for any use of this material against systems they do not own or have permission to test.
