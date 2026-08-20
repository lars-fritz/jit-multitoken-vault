# JIT multi-token vault - Uniswap v4 prototype

This Foundry project implements the first literal version of the proposed
mechanism:

1. a three-token vault issues proportional fungible fund shares;
2. three v4 pools share one mandatory `beforeSwap` hook;
3. a coordinator borrows the complete pair inventory from the vault;
4. it creates two temporary positions around price, with widths determined by
   oracle volatility and relative vault inventory;
5. it executes one exact-input swap;
6. it removes the complete temporary position;
7. it pays the trader and returns the residual pair inventory to the vault.

No vault-backed liquidity remains in a pool after the transaction.

The complete mechanism, accounting equations, range policy, and open research
questions are described in the [working paper](whitepaper/jit-multitoken-vault-whitepaper.pdf).
Its editable LaTeX source is [included alongside it](whitepaper/main.tex).

## Contracts

- `src/JITFundVault.sol` - proportional basket shares and atomic inventory lock.
- `src/interfaces/IVaultOracle.sol` - price and relative-volatility adapter used
  for NAV and range construction.
- `src/JITSwapHook.sol` - rejects swaps unless the approved coordinator has an
  active JIT cycle for that exact pool.
- `src/JITSwapCoordinator.sol` - PoolManager unlock callback, temporary
  liquidity, swap, removal and settlement.
- `src/mocks/MockERC20.sol` - test token only.

## Run the tests

```sh
forge build
forge test --offline -vv
```

The `--offline` flag avoids a macOS Foundry signature-lookup crash observed in
the development environment. It is not a protocol requirement.

Current tests demonstrate:

- proportional deposit and in-kind withdrawal;
- oracle-valued single-token deposit;
- inventory-asymmetric, volatility-scaled two-wing ranges;
- an X/Y exact-input trade using temporary vault liquidity;
- zero coordinator balances and an unlocked vault after settlement;
- X/Y -> Z/Y -> Y/X cross-pair sequencing;
- rejection of a swap submitted through an ordinary bypass router.

## Pool and hook deployment

Every supported pool must be created with this hook address in its `PoolKey`.
V4 derives enabled callbacks from the low bits of the hook address, so the hook
must be deployed with `Hooks.BEFORE_SWAP_FLAG` set. The test uses Foundry's
`deployCodeTo`; a deployment script should mine a CREATE2 salt with Uniswap's
HookMiner and then call `validateHookAddress()`.

Deployment order:

1. Deploy `PoolManager` or select an official deployment.
2. Deploy `JITFundVault` with three distinct ERC20 assets.
3. Deploy the hook to a BEFORE_SWAP address.
4. Deploy `JITSwapCoordinator` with the manager and vault.
5. Set the coordinator on both vault and hook.
6. Initialize the three sorted pair pools with the hook.
7. Register all three `PoolKey`s in the hook.
8. Configure each pool's base/maximum width, volatility multiplier, inventory
   skew, wing allocation, overlap, maximum tick movement and trade percentage.
9. Bootstrap the vault basket and fund protocol-owned seed positions if wanted.

Traders call only:

```solidity
swapExactIn(key, zeroForOne, amountIn, minAmountOut, recipient)
```

They cannot provide ticks or a square-root price limit. For each pool, the
owner-controlled `PoolRiskConfig` defines:

- `baseHalfWidthTicks` and `maxHalfWidthTicks`: governed volatility width bounds;
- `maxTickMove`: maximum terminal movement for one swap;
- `maxTradeBps`: input size as a fraction of the vault's input-token inventory;
- `volatilityWidthFactorBps`: response to adapter-reported relative volatility;
- `inventorySkewFactorBps`: response to deviation from target weights;
- `primaryTokenAllocationBps`: amount assigned to the natural token side of
  each wing;
- `overlapTicks`: small active overlap around current price;
- `enabled`: pool-level emergency switch.

The coordinator rejects partial fills, so reaching the terminal price limit
reverts the entire operation instead of treating unspent trader input as fund
assets.

## Deliberate prototype assumptions

This version is for local testing, not deployment with real assets.

- ERC20 pairs only; native currency is rejected.
- Exact-input swaps only.
- Single-token deposits and volatility widths depend on a freshness-checked
  oracle adapter. The included mock is test-only; a production v3 TWAP adapter
  remains required.
- Range and terminal-price policies are configured by the coordinator owner.
- The configured range must align with tick spacing and contain the current tick.
- The vault lends its complete pair inventory during the atomic operation.
- Fee-on-transfer, rebasing and callback-bearing tokens are unsupported.
- The generic oracle interface, volatility response, inventory skew, and
  maximum-trade policy are implemented; robust reference adapters are not.
- There is no epoch/batch protection against cross-pair ordering.
- There is no protocol fee or governance delay.
- The coordinator assumes vanilla v4 balance deltas from this non-return-delta
  hook.
- Native v4 rounding can leave several wei in PoolManager during two
  add/remove round trips; tests explicitly bound this dust.

## Priority security work

Before even a testnet pilot with valuable tokens:

1. Implement and validate a deep-market v3 TWAP/realized-volatility adapter,
   cross-source checks, and deposit-specific oracle windows.
2. Define the refresh policy: per swap, persistent virtual range, or epoch.
3. Add a canonical cross-price policy across all three pools.
4. Fuzz arbitrary pair sequences and search profitable triangular cycles.
5. Fuzz deposits and withdrawals around swaps and rounding boundaries.
6. Add invariant tests for total assets, no residual liquidity, no residual
   coordinator balances, and lock release after every successful call.
7. Add malicious ERC20, reentrancy and multi-tick edge-case tests.
8. Decide whether external liquidity is allowed. The current hook blocks direct
   swaps, but anyone may add liquidity because liquidity hooks are not enabled.
9. Replace the owner with appropriate governance and emergency controls.
10. Obtain independent review and audit.

## Central research question

Because a new range is created for every trade, splitting an order can receive
different execution from submitting it once. Since all pairs use one vault, a
trade in Y/Z also changes the inventory used by the next X/Y range. Those are
intentional model properties and need economic tests, not merely Solidity tests.
