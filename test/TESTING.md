# Additional adversarial coverage

This suite extends the original tests using the real vendored PoolManager and
Tidal contracts. It needs no network, fork, external package, FFI, or generated
file. Run from the repository root:

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0x8f0a3c24e6f00ce9ac32585677a7dbf2ca1daacd4e765dfba38a34ae92af5d7a forge test --offline
```

The additions are:

| File | Properties and failure cases |
| --- | --- |
| `FeeBoundaryProperties.t.sol` | Floor/ceiling inequalities across the int128 domain; the largest valid net ETH output and the next wei; overflow, zero-output and wrong-sign rejection; first fee wei; repeated buy/sell cycles cannot create ETH. |
| `AtomicSettlement.t.sol` | All four swap modes netted in one unlock; two unpaid buys on a fresh manager mint claims; live transient hook deltas equal zero; nested unlock failures are retryable; buyback settlement clears a preceding token sync. |
| `FailureAtomicity.t.sol` | Full economic-state rollback after underfunded routing, partial native fills, failed slippage, absent liquidity, or rejected payouts; payout reentry by a treasury that is also owner; cancelled/replaced ownership nominations; block-based timing; receive authorization. |
| `LifecycleInvariant.t.sol` | Multiple traders and treasuries, changing owners, real claim redemption, buys/sells, buybacks, donations, holder burns, and rejected calls in random order. Includes independent receipt and price-history models. |
| `UnequalPriceFlows.t.sol` | All four swap modes, claim-backed and cash-backed fees, payout and actual burn at approximately 50 million TIDAL per ETH. The price is a local scenario, not a deployment setting. |

## Stateful properties

The lifecycle suite uses 256 sequences of 64 calls with unexpected reverts treated
as failures. Its three invariant functions run after each call. The original
accounting suites continue to cover their original call surfaces. Added stateless
fuzz properties use 1,000 examples, configured inline in their test files.

The property selection considered conservation, rounding/round trips, state
transitions, adversarial extraction/liveness, and v4/ERC-20-specific guarantees:

- **Conservation:** fees are measured from actual ETH and ERC-6909 receipts, not
  copied from `totalFeesCollected`. Treasury receipts and buyback costs are
  independently measured. Pending allocations plus payments must partition the
  receipts exactly, with at most the specified one-wei rounding difference.
- **Surplus isolation:** forced ETH, externally funded ERC-6909 claims, and
  transferred TIDAL are tracked separately. They cannot inflate fee allocations
  or buyback/treasury counters. The invariant accounts for them explicitly instead
  of assuming the hook can never receive donations.
- **Supply:** every token is in a known holder's balance or has actually been
  burned. Independent holder burns and hook buyback burns have separate counters;
  a holder burn must not be attributed to the hook. Donated tokens remain outside
  the amount bought and burned.
- **State transitions:** pending ownership does not confer authority; acceptance
  does not redirect the treasury. Initialization and the launch block persist.
  Invalid calls have exact expected errors and leave a digest of economic state
  unchanged. Successful treasury payments reach only the configured recipients.
- **Volatility:** the handler records raw absolute tick changes from the real
  PoolManager in a mapping keyed by absolute block number. A history-based oracle
  checks the hook's capped, decaying eight-slot ring. It includes buyback price
  changes, multiple swaps in a block, idle gaps, and slot reuse. Block advances
  cannot increase an otherwise idle market's dynamic fee.
- **Rounding and extraction:** inequalities check both rounding directions without
  duplicating the fee division. Repeated buy/sell round trips must lose ETH while
  restoring the trader's token balance. Native exact-output requests retain their
  net ETH amount, and buyback operators receive no funds or purchased tokens.
- **v4 settlement:** `AtomicProbe` inspects deltas inside `unlockCallback`, while
  they are live. Hook deltas must already be settled when a swap returns; the
  probe then settles its aggregate deltas and checks the manager before and after
  relocking. This avoids relying solely on reads after Foundry clears transient
  storage between top-level test calls.

`test_handlerReachesAllStatefulPaths` deterministically exercises each handler
category and checks operation counters. A second deterministic sequence reuses
observation slots repeatedly. Valid handler operations are not enclosed in broad
`try/catch` blocks. Empty allocations can make a claim/redemption/buyback handler
return; the deterministic sequence explicitly verifies successful execution of
each of those paths.

## Scope

The fixture bounds permit full swaps and affordable buybacks throughout the
random sequences. Separate unit tests cover small amounts, maximum arithmetic
inputs, partial fills, missing liquidity, and failures beyond those bounds.
`HookState` includes pool price, tick, liquidity, LP fee growth, hook allocations,
cash, claims, supply, roles, and observations in rollback comparisons.

The suite assumes the project's actual PoolManager and standard TidalToken. It
does not replace them with mocks to manufacture impossible settlement return
values. It tests local behavior; it does not claim a chain deployment rehearsal
or protection against every economic attack. A failed test must be investigated
as either a harness error or a contract defect, not rewritten to bless a defect.
