# Vendored dependencies

All files are ordinary repository files. No submodule, package manager download,
or network access is needed by the build. Exact source revisions are recorded in
[versions.json](versions.json).

| Dependency | Revision | Included material |
| --- | --- | --- |
| Uniswap/v4-core | `bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6` | Core sources, interfaces, libraries and licenses; upstream test helpers omitted |
| foundry-rs/forge-std | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` (v1.9.7) | Solidity test library and licenses |
| OpenZeppelin/openzeppelin-contracts | `69c8def5f222ff96f2b5beff05dfba996368aa79` (v5.1.0) | ERC20, Ownable2Step, ReentrancyGuard and their import dependencies; license |
| transmissions11/solmate | `89365b880c4f3c786bdd453d4b8e8fe410344a69` | Owned, required by the test PoolManager; license |

Sources came from each repository's GitHub archive at the stated commit.
Licenses remain in each dependency directory; SPDX declarations remain in source.
Uniswap core has per-file licensing (including BUSL-1.1 for PoolManager); do not
assume the complete dependency tree is licensed under the application files' MIT
license.

## Local changes to v4-core

1. **`src/libraries/BitMath.sol`:** replaced the assembly lookup implementations
   of most/least significant bit with a fixed eight-stage Solidity binary search.
   This removes the nested constant-table shifts rejected by the previous static
   check. The precondition (`x > 0`), bit numbering, function signatures, and
   outputs are unchanged. There are no analyzer suppressions. Regression tests
   cover all 256 single-bit values, adjacent values, zero rejection, random values
   against a simple loop, and downstream TickMath round trips. This is a source
   change to the vendored library, not a claim that upstream's arithmetic was wrong.
2. **`src/libraries/FullMath.sol`:** explicitly toggle bit 1 of the inverse seed
   using addition/subtraction instead of `(3 * denominator) ^ 2`. The original XOR
   is mathematically intentional; treating it as exponentiation would be a bug.
   Within the existing unchecked block, the new expression is equivalent for all
   uint256 values and avoids the incorrect-exp diagnostic. Regression tests cover
   full-width multiplication with independent quotient/remainder decomposition,
   full-width denominator cancellation, extremes, rounding, and rejected overflow.
3. **`src/libraries/Hooks.sol`:** initialize the local `hookDelta` to
   `BalanceDeltaLibrary.ZERO_DELTA` explicitly. This preserves Solidity's existing
   default-zero behavior and removes the uninitialized-local diagnostic.

No PoolManager economics, storage layout, hook dispatch, or delta semantics have
been changed. The test PoolManager is compiled from this vendored source; production
uses the actual manager supplied by the launch. Gas use of the binary-search
BitMath implementation may differ from upstream. The remaining upstream modular
math and tick-rounding operations are intentionally retained.
