# Tidal: volatility fees, launch protection, and buyback burn

A Foundry project for the ETH/TIDAL Uniswap v4 launch. It deploys `TidalToken` and
`TidalHook`. All dependencies needed for compilation and tests are ordinary files
under `deps/`; no package installation, submodules, network, RPC, environment
variables, FFI, or filesystem cheatcodes are needed to run the tests.

## Economics and assumptions

**The requested fees are hook fees, additional to the launch policy's fixed
1.25% LP fee.** The policy requires `PoolKey.fee = 12500`, not the dynamic-fee
flag. The hook never overrides that LP fee. The 50/50 split described below applies
to fees collected by the hook; LP fees stay with liquidity positions under the
launch factory's separate policy.

- Tidal (`TIDAL`): 18 decimals, exactly 1,000,000,000 tokens (`10^27` units)
  minted once to the deploying factory. Transfers are ordinary ERC-20 transfers.
  No owner, subsequent minting, pause, blocklist, transfer tax, or upgrades.
  `burn(amount)` destroys only the caller's tokens and reduces `totalSupply`.
  Thus the initial supply is fixed and subsequent supply can only decrease.
- The hook supports exactly one native-ETH/TIDAL pool, fee `12500`, tick spacing
  `60`. Native ETH is currency0; TIDAL is currency1. Other tokens and pools are
  rejected. The zero currency address denotes native ETH; it is not a recipient
  or an unset deployment address.
- Opening means successful `PoolManager.initialize` by the specified factory.
  It starts the launch window even if liquidity is seeded later. The factory
  should deploy, initialize, and seed in one transaction.
- A creator's treasury defaults to the explicit launch owner. The owner may
  change the treasury recipient, including for already accrued treasury fees.
- Buybacks are batched, owner-operated swaps in this same pool. Allocation is
  automatic on each user swap; execution needs an owner transaction with a
  price limit, minimum token output, and deadline. Pending allocation is not
  represented as already burned. The owner cannot withdraw buyback funds.

## Fee calculation

All rates are integer fee-pips with denominator `1_000_000`.

The base dynamic component is `3000` (0.30%) and its cap is `20000` (2.00%).
The short-term signal is cumulative **absolute tick movement** between successive
swaps. A tick represents a factor of 1.0001 in price, making this an approximation
of absolute log-price volatility, rather than a percentage change of raw reserves.

For each block `b`, record `M_b = min(sum(abs(tick_after - tick_before)), 340)`.
There are eight observation slots, one per block modulo eight. At block `n`:

```text
weightedMovement = sum(M_b * (8 - (n - b))) for 0 <= n - b < 8
premiumPips      = min(17000, floor(weightedMovement * 50 / 8))
dynamicFeePips   = 3000 + premiumPips
launchFeePips    = 10000 * (20 - age) if age < 20, otherwise 0
age             = n - launchBlock
hookRate        = dynamicFeePips + launchFeePips
```

The chosen window is **8 blocks**, sensitivity **50 fee-pips per tick**, and
per-block saturation **340 ticks**. These are immutable named constants. One
isolated shock's contribution decays linearly to zero over eight blocks, including
when no transactions occur. Contributions from different blocks age independently.
A round trip counts both price movements. Within a block, tiny swaps cannot erase
an earlier shock or reset the launch clock.

The launch surcharge is 20% in the initialization block, 19% in the next block,
1% at age 19, and zero at age 20. It is **additional** to the dynamic component:
the hook's maximum combined rate is 22% during launch and 2% afterward. The first
swap starts at 20.30%. The LP fee is additional and is not simply added to the hook
rate to quote a user's total cost, since their bases differ.

A swap uses the signal available **before** it executes. Its price movement
influences subsequent swaps, including subsequent swaps in the same block.
Buyback swaps also update observations. This signal is manipulable at a trading
cost; it is a bounded fee input, **not a fair-value oracle or a sandwich guarantee**.

## Swap settlement and rounding

The hook collects fees exclusively in native ETH, never in TIDAL. Let `r` be the
hook rate and `D = 1_000_000`:

| Swap | ETH fee | Collection delta | Partial fill |
| --- | --- | --- | --- |
| Buy, exact ETH input `A` | `floor(A*r/D)`; pool receives `A-fee` | Specified, beforeSwap | Reverts unless adjusted ETH input fills completely |
| Buy, exact TIDAL output | `ceil(poolETHInput*r/(D-r))` | Unspecified, afterSwap | Supported; router must enforce requested output if required |
| Sell, exact TIDAL input | `floor(poolETHOutput*r/D)` | Unspecified, afterSwap | Supported; charged on actual ETH output |
| Sell, exact net ETH output `A` | `ceil(A*r/(D-r))`; pool outputs `A+fee` | Specified, beforeSwap | Reverts unless adjusted ETH output fills completely |

The beforeSwap callback returns the specified delta but takes nothing until
successful afterSwap. v4 allows afterSwap to adjust only the unspecified side.
Therefore native-specified partial fills deliberately revert atomically rather
than charging on an unfilled amount. Integrators must retain price limits, budget
checks, and minimum output checks; do not remove those checks to force a fill.
Empty/no-output swaps are rejected. Amounts are checked before narrowing to int128.
`hookData` does not grant an exemption and no router or sender is fee-exempt.

If the PoolManager holds enough ETH during the callback, the fee is taken as ETH
to the hook. Otherwise the hook mints an ETH ERC-6909 claim against the manager.
This permits the first buy on a token-only seeded pool, before the router settles
its ETH input. `redeemClaims(amount)` is permissionless and converts the hook's
claims to ETH held by the hook, without paying the caller. Treasury claims redeem
only their ETH shortfall automatically; buybacks can spend claims directly.
Redemption requires the manager to be locked on entry and able to transfer the ETH.
Failure rolls back all accounting and can be retried later.

At every collection the fee is split 50/50. Cumulative treasury allocation is
`floor(totalFeesCollected/2)`; cumulative buyback allocation receives the remaining
wei. A single odd wei goes to buyback until the next odd collection balances it.
Small swap fees round as shown in the table. No additional execution or keeper fee
is deducted.

## Deployment parameters

Compile with Solidity **0.8.26**, EVM **Cancun**, optimizer 200 runs, and
`bytecode_hash = "none"`, as pinned in `foundry.toml`. The hook runtime is below
EIP-170's 24,576-byte limit; a test checks it. There are no external library links.

The launch is Sepolia (chain 11155111); there is no hardcoded chain-specific
PoolManager or token address. The factory/deployer supplies these parameters:

| Contract / argument | Value / source |
| --- | --- |
| `TidalToken()` | No arguments; factory receives the whole initial supply |
| `TidalHook.manager_` | `$poolManager`, the launch's actual `IPoolManager` |
| `TidalHook.token_` | `$token`, the TidalToken deployed by this launch |
| `TidalHook.initialOwner` | `$owner`, the requester-selected launch owner |
| `TidalHook.factory_` | `$factory`, the actual launch factory that initializes the pool |

All four hook arguments are nonzero addresses. Construction makes no external
calls and does not require dependencies to have code yet. Their correct identity
is a deployment responsibility, not something an ABI address can prove. The hook
is never owned by constructor `msg.sender` or `tx.origin`.

1. Deploy the token from the launch factory.
2. Encode the four hook constructor arguments. Mine a CREATE2 salt against the
   **actual CREATE2 deployer** and `keccak256(creationCode ++ abi.encode(args))`.
   The hook address's low 14 bits must equal **`0x10cc` (4300)**. Changing any
   argument, compiler setting, or bytecode requires recomputing the salt. The
   constructor validates the complete permission mask; an arbitrary CREATE address
   will generally revert. Tests mine and actually deploy with CREATE2.
3. Enable exactly `afterInitialize`, `beforeSwap`, `afterSwap`,
   `beforeSwapReturnDelta`, and `afterSwapReturnDelta`. Initialization is included
   to validate the factory and pool and establish the launch clock. Swaps and
   both return deltas implement the four settlement cases above. Liquidity and
   donation callbacks are disabled; LP fee collection with zero liquidity change
   and liquidity withdrawal remain unrestricted by the hook.
4. Initialize `hook.getPoolKey()` **from `$factory`**. Accept the factory-derived
   opening price for its 20 ETH opening market-cap policy; do not replace it with
   the nominal one-to-one price used in local tests. The hook does not constrain
   the factory's valid starting price. The factory distributes and seeds the
   initial token supply according to the launch policy (10% distributor, 88% pool,
   2% payer/treasury); the hook has no genesis allocation.
5. Confirm `initialized`, `launchBlock`, `owner`, `treasury`, the pool ID, and address
   flags. There is no helper contract to deploy, no router to configure, and no
   `launch.json` in this deliverable; the later manifest step supplies it.

## After launch

- **Treasury recipient:** optional `setTreasury(address)` by the owner. Set it to
  the creator's intended receiving wallet or treasury contract, obtained from the
  creator. The default is `$owner`. Use an address able to receive ETH; zero, the
  hook, its token, and its manager are rejected. Anyone can call `claimTreasury()`;
  the ETH always goes to the configured recipient. A rejecting recipient blocks
  only its payout, not trading or buybacks; the owner can correct the address.
- **Buybacks:** the owner monitors `buybackAccrued` and calls
  `executeBuyback(maxEthIn, minTokensOut, sqrtPriceLimitX96, deadline)` regularly.
  Obtain an independent quote for the same pool, account for the 1.25% LP fee,
  choose a small tranche relative to liquidity, and set a meaningful minimum output
  and price limit. A 1% maximum quote slippage and a short deadline are suggested
  operating limits, not a protocol oracle. The contract requires positive minimum
  output, a price limit strictly below the current price and above TickMath's
  minimum, and a deadline no more than 30 minutes ahead. Protected transaction
  submission is recommended for owner buybacks. A compromised owner can choose
  poor bounds; the contract cannot identify fair value.
- **Burn:** buyback execution receives TIDAL into the hook and calls the token's
  holder-only `burn` in the same transaction. The owner receives neither tokens nor
  ETH. A price-bound partial fill restores unused ETH to `buybackAccrued`. A failed
  minimum output, absent liquidity, or expired deadline reverts the whole operation;
  leave the allocation queued and retry with a new quote. Buybacks pay the pool's
  LP fee but no recursive hook fee, using v4's self-call callback exclusion.
- **Claims:** anyone may call `redeemClaims(amount)` after swap settlement. Claims
  and ETH back the same segregated allocations; redemption does not allocate new
  fees. Watch `claimsOutstanding` and `ClaimsRedeemed` for delayed settlement.
- **Ownership:** transfers use `transferOwnership` then `acceptOwnership`. The
  treasury address remains unchanged until explicitly set. Renunciation is disabled
  to preserve a buyback operator. Use an owner capable of making these calls and
  keeping quotes current. No keeper service is supplied or paid by this contract.
- **Monitoring:** track `FeeCollected`, `BuybackBurned`, `TreasuryPaid`,
  `PriceObserved`, owner/treasury changes, pending balances, and unusually long
  delays between allocation and burning. Lost owner access can leave buybacks
  queued indefinitely; treasury claims and swaps still work.

There are no fee setters, pause switches, upgrades, administrative drains, or
arbitrary external call targets. Foreign tokens, unsolicited ERC-6909 claims, and
forced ETH are not allocated as fees and have no recovery function.

## Checks

```sh
forge build
forge test --fuzz-seed 0x8f0a3c24e6f00ce9ac32585677a7dbf2ca1daacd4e765dfba38a34ae92af5d7a
forge fmt --check
```

`forge test --offline` also works once the pinned compiler is available. The project
uses a real local PoolManager, including its transient balance accounting, rather
than a mocked swap implementation. Tests cover all four fee paths on funded and
fresh managers, partial fills, launch boundaries, volatility and decay, ownership
and callbacks, payout rejection/reentrancy, claim fallback/redemption, buyback
bounds/rollback/burning, LP withdrawal/fee collection, patched arithmetic, fuzzing,
and two stateful invariant suites. Each invariant suite runs 128 sequences of
32 calls with unexpected reverts treated as failures.

Read [the security review](docs/SECURITY_REVIEW.md) and
[dependency provenance and patches](deps/PATCHES.md). These checks are local
engineering validation, not an independent audit or a Sepolia fork rehearsal.
Independent review, the launch factory's chain rehearsal, deployment, and explorer
verification remain release responsibilities. No transactions were broadcast.

The implementation follows the pinned core interfaces and Uniswap's
[flash-accounting model](https://developers.uniswap.org/docs/protocols/v4/concepts/flash-accounting)
and [hook permission model](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks).
