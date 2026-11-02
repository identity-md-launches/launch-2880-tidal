# Implementation review

This is the implementation author's review using the supplied Ethereum and v4
security references. It is not an independent audit. No Slither or Mythril run,
fork rehearsal, live deployment, or explorer verification is claimed.

## Boundaries and access

- `afterInitialize`, `beforeSwap`, `afterSwap`, `unlockCallback`, and the native
  receive function require the immutable PoolManager caller.
- Initialization additionally authenticates the immutable factory, validates the
  entire pool ID against native ETH/TIDAL/12500/60/this hook, and runs once.
- The deployment constructor validates hook address bits against all permission
  flags. The required initialization callback prevents opening the predicted pool
  while no hook code exists. Tests deploy using actual CREATE2, not `vm.etch`.
- Owner is an explicit constructor argument, never constructor caller or origin.
  Owner changes are two-step. There is no proxy, delegatecall, selfdestruct, mint
  authority, arbitrary call facility, or emergency balance sweep.
- Treasury changes and price-bounded buybacks require the owner. Claims and claim
  redemptions are permissionless but cannot choose their own payout recipient.
- No user identity is decoded from hookData, and no router allowlist is necessary:
  everyone pays the same formula. A hookData identity cannot exempt a trade.

## Deltas, fees and NoOp exposure

- beforeSwapReturnDelta is necessary to charge ETH when it is the specified side.
  On exact-input buys its positive delta is at most 22% of input, so it cannot
  consume all user input or silently replace the entire swap. Exact-output sells
  are grossed up, retaining the user's exact net ETH output.
- The charge is taken only in afterSwap, which confirms a nonzero trade and a full
  adjusted native-specified fill. In token-specified modes the fee uses actual ETH
  delta, supporting partial fills. A failed settlement rolls back the whole swap.
- Returned hook deltas and `take`/`mint` offsets balance. Stateful tests assert zero
  manager currency deltas and a relocked PoolManager after every operation.
- The fee rate is bounded by constants; no owner can raise it. Volatility is a
  trailing price-change heuristic, not an oracle. The current swap updates only
  subsequent rates. Block contributions fade rather than persisting indefinitely.
- Fresh-manager fees mint claims when ETH has not arrived yet. That path is tested
  on a pool genuinely seeded only with tokens, without dealing ETH to the manager.
  Claims can fund buybacks directly or be redeemed through an authenticated unlock.
- Fees owed to LP positions are separate. No liquidity callback is enabled, so
  neither owner settings nor hook fees block factory fee collection or LP exits.

## Asset conservation

With `F = totalFeesCollected`, the following hold, ignoring unrelated donations:

```text
treasuryAccrued + totalTreasuryPaid = floor(F / 2)
buybackAccrued + totalBuybackSpent  = F - floor(F / 2)
hook ETH + tracked ETH claims      = treasuryAccrued + buybackAccrued
manager ERC-6909 balance (id 0)     = claimsOutstanding
```

The last equality assumes no third party transfers unsolicited claims to the hook;
such donations are ignored, not allocated to fees. Forced ETH similarly creates a
surplus, not a spending entitlement. Tests hold the equality in undonated states.
The buyback counter tracks only burns performed by this hook; other token holders
can independently burn their own TIDAL.

Cumulative rounding carries odd wei across swaps, keeping allocations within one
wei of an exact half split. Successful buybacks take actual TIDAL then call burn,
reducing totalSupply. Partial fills restore unused budget. There is no token sweep
or owner refund path.

## Reentrancy and external interactions

- Treasury claims, redemptions, treasury updates, and buybacks use ReentrancyGuard.
  The claim balance is cleared and paid totals updated before payout. A rejecting
  treasury reverts only its claim; reentry cannot withdraw the balance twice.
- Unlock authorization is private, set only before a hook-initiated unlock and
  consumed at callback entry. The callback checks its manager and allowed action.
- Ordinary swap callbacks interact only with the trusted manager; ETH returns to
  the hook's manager-only receive function, which performs no external calls.
- The immutable token must be this project's standard TidalToken. No ERC-777,
  rebase, transfer fee, arbitrary pair token, or externally upgraded token is
  supported. Deployment must supply the correct token and manager.
- Buybacks use the same pool and a fixed buy direction. v4 intentionally excludes
  the initiating hook from its own swap callbacks; the hook therefore records the
  resulting price itself. This exclusion cannot be requested by an outside router.
- Paying native ETH explicitly syncs the native currency before settle, preventing
  interference from a prior ERC-20 sync. Claim burning and settlement amounts are
  bounded, and settlement return values are checked.

## Known economic and operational limits

1. **MEV and manipulable prices:** a trader can raise bounded future fees by moving
   the pool price. The launch surcharge discourages sniping but does not prohibit
   bots. Eight-block volatility is not used to price buybacks. The owner must choose
   buyback limits from an independent quote and account for liquidity and MEV.
2. **Owner operation:** allocation does not itself schedule a transaction. The
   owner must execute buybacks and can delay them indefinitely or choose bad bounds.
   Even then buyback allocation cannot be directly withdrawn as treasury proceeds.
   There is no on-chain fair-value feed supplied by this task.
3. **Native-specified partial fills:** these revert, deliberately. This is a
   documented router compatibility constraint, not an untested partial-fill fee
   assumption. Other swap modes support actual partial-fill accounting.
4. **Liquidity and failed recipients:** buybacks need available liquidity;
   redemptions need sufficient settled manager ETH. A rejecting treasury must be
   replaced by the owner. Failure preserves balances for retry.
5. **Outside pools:** the standard token can trade elsewhere without this hook.
   Launch protection and fees apply only to the canonical hooked pool.
6. **Immutable deployment:** there is no upgrade or pause recovery. Correct factory,
   manager, owner, token, CREATE2 salt, price and network selection require review.

## Verification evidence

Local tests exercise a real PoolManager on Cancun with Solidity 0.8.26. They include
successful and failing callback/initialization paths, runtime opcode and size
checks, four swap modes, funded/token-only managers, exact fee rounding, partial
fills, launch boundaries, volatility response and expiration, claim redemption,
reentrant/rejecting treasury recipients, ownership, buyback slippage and rollback,
actual token destruction, liquidity fee collection/withdrawal, and math regression.

Two invariant suites each execute 128 sequences of 32 randomized calls across
swaps, block advances, redemptions, payouts, and buybacks, with `fail_on_revert = true`.
The second starts with fresh-manager claims. Independent receipt calculations
check collected fees while invariants check assets, allocation, supply, rate caps,
and fully settled deltas. The mandated fuzz seed is shown in the README.

The previous blocker in vendored BitMath has been removed from source, not hidden
behind analyzer settings. The precise changes and test rationale are in
[deps/PATCHES.md](../deps/PATCHES.md). Release still requires the separate
contributor review and launch-chain rehearsal described in the assignment.

Final local validation: a clean `forge build` compiled 85 files using Solidity
0.8.26; the offline test run passed **57 tests, zero failures and zero skips** with
the supplied seed. The two invariant suites completed **8,192 total calls with
zero unexpected reverts**. `forge fmt --check` passed. Both application artifacts
have empty external library link references. Build lints include advisory findings;
passing the build is not represented as passing independent static analysis.
