# NOTICE

This repository contains both original code and third-party code.

## Original code (MIT)

The following files are original work and are licensed under the MIT License
(see `LICENSE`):

- `contracts/AttackBiswapBurn.sol`
- `contracts/mocks/MockERC20.sol`
- `contracts/mocks/MockBiswapFactory.sol`
- `test/BiswapV3Burn.test.js`
- `test/BiswapV3Burn.fork.test.js`
- `scripts/fork-check.js`
- `README.md`, `NOTICE.md`, and other documentation

## Biswap V3 verified sources (BUSL-1.1)

The files under `contracts/biswap/` are copied from the verified on-chain
sources of the Biswap V3 contracts on BNB Smart Chain, retrieved from
Sourcify. They retain their original SPDX headers:

```
// SPDX-License-Identifier: BUSL-1.1
```

These files include, among others:

- `contracts/biswap/core/BiswapPoolV3.sol`
- `contracts/biswap/core/liquidity.sol`
- `contracts/biswap/core/swapY2X.sol`
- `contracts/biswap/interfaces/*`
- `contracts/biswap/libraries/*`

`contracts/fixed/LiquidityModuleFixed.sol` is a modified copy of
`contracts/biswap/core/liquidity.sol` and is therefore also distributed under
BUSL-1.1.

The Business Source License 1.1 text is included in
`LICENSES/BUSL-1.1.txt`. The BUSL-1.1 permits copying, modifying, and
non-production use of the licensed work. This repository uses the code for
security research and testing. It does not grant any production-use rights
beyond those in the license. The licensor's Change Date and Change License
terms apply.

## Trademarks

Biswap, iZiSwap, Uniswap, BNB Chain, PancakeSwap, and other names are
trademarks of their respective owners. This repository is not affiliated with
or endorsed by any of them.
