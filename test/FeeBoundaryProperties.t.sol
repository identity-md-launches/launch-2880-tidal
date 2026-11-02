// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {TidalHook} from "src/TidalHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract FeeBoundaryPropertiesTest is Fixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_beforeSwapRoundsWithoutConsumingTheTrade(
        uint128 raw,
        uint8 age,
        bool shock,
        bool buy,
        bool exactInput
    ) public {
        vm.roll(hook.launchBlock() + bound(age, 0, 30));
        if (shock) _swap(true, -50 ether);
        uint256 amount = bound(raw, 1, uint256(uint128(type(int128).max)) / 2);
        uint256 rate = hook.quoteFeePips();
        uint256 feesBefore = hook.totalFeesCollected();
        uint256 heldBefore = address(hook).balance;
        uint256 claimsBefore = hook.claimsOutstanding();
        SwapParams memory params = SwapParams(
            buy,
            exactInput ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpOverride) =
            hook.beforeSwap(stranger, key, params, abi.encode(creator, true));
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(lpOverride, 0, "hook must not replace launch LP fee");
        assertEq(delta.getUnspecifiedDelta(), 0);
        uint256 fee = uint256(uint128(delta.getSpecifiedDelta()));
        if (buy && exactInput) {
            // Floor expressed as inequalities, independent of the implementation's division.
            assertLe(fee * D, amount * rate);
            assertGt((fee + 1) * D, amount * rate);
            assertLt(fee, amount, "NoOp: some input must reach the pool");
        } else if (!buy && !exactInput) {
            // Minimal gross-up that funds the rate while preserving the requested net output.
            assertGe(fee * (D - rate), amount * rate);
            assertGt(fee, 0);
            assertLt((fee - 1) * (D - rate), amount * rate);
            assertLe(amount + fee, uint256(uint128(type(int128).max)));
        } else {
            assertEq(fee, 0, "token specified: ETH fee belongs in afterSwap");
        }
        assertEq(hook.totalFeesCollected(), feesBefore, "quote cannot collect");
        assertEq(address(hook).balance, heldBefore);
        assertEq(hook.claimsOutstanding(), claimsBefore);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_largestRepresentableNetETHOutputAndNextWei(uint8 age, bool shock) public {
        vm.roll(hook.launchBlock() + bound(age, 0, 30));
        if (shock) _swap(true, -50 ether);
        uint256 rate = hook.quoteFeePips();
        uint256 maximum = uint256(uint128(type(int128).max));
        uint256 lastValid = maximum * (D - rate) / D;
        vm.prank(address(manager));
        (, BeforeSwapDelta delta,) = hook.beforeSwap(
            stranger, key, SwapParams(false, int256(lastValid), TickMath.MAX_SQRT_PRICE - 1), ""
        );
        assertLe(lastValid + uint256(uint128(delta.getSpecifiedDelta())), maximum);
        vm.prank(address(manager));
        vm.expectRevert(TidalHook.InvalidAmount.selector);
        hook.beforeSwap(
            stranger, key, SwapParams(false, int256(lastValid + 1), TickMath.MAX_SQRT_PRICE - 1), ""
        );
    }

    function test_maximumNativeInputIsQuotedWithoutNarrowingOverflow() public {
        uint256 maximum = uint256(uint128(type(int128).max));
        vm.prank(address(manager));
        (, BeforeSwapDelta delta,) = hook.beforeSwap(
            stranger, key, SwapParams(true, -int256(maximum), TickMath.MIN_SQRT_PRICE + 1), ""
        );
        uint256 fee = uint256(uint128(delta.getSpecifiedDelta()));
        assertLe(fee * D, maximum * 203_000);
        assertGt((fee + 1) * D, maximum * 203_000);
        assertLt(fee, maximum);
    }

    function test_afterSwapRejectsGrossETHInputBeyondInt128() public {
        int128[2] memory amounts = [-type(int128).max, type(int128).min];
        for (uint256 i; i < amounts.length; ++i) {
            vm.prank(address(manager));
            vm.expectRevert(TidalHook.InvalidAmount.selector);
            hook.afterSwap(
                stranger,
                key,
                SwapParams(true, 1, TickMath.MIN_SQRT_PRICE + 1),
                toBalanceDelta(amounts[i], 1),
                ""
            );
        }
        assertEq(hook.totalFeesCollected(), 0);
        _assertAccounting();
    }

    function test_bothCallbacksRejectAllOutOfRangeSpecifiedAmounts() public {
        int256 maximum = int256(type(int128).max);
        int256[5] memory invalid = [int256(0), maximum + 1, -maximum - 1, type(int256).min, type(int256).max];
        for (uint256 i; i < invalid.length; ++i) {
            for (uint256 side; side < 2; ++side) {
                SwapParams memory params = SwapParams(side == 0, invalid[i], Q96);
                vm.prank(address(manager));
                vm.expectRevert(TidalHook.InvalidAmount.selector);
                hook.beforeSwap(stranger, key, params, "");
                vm.prank(address(manager));
                vm.expectRevert(TidalHook.InvalidAmount.selector);
                hook.afterSwap(stranger, key, params, BalanceDelta.wrap(0), "");
            }
        }
        _assertAccounting();
    }

    function test_afterSwapRejectsZeroOutputAndWrongSignedDeltas() public {
        BalanceDelta[5] memory invalidBuys = [
            toBalanceDelta(-1000, 0),
            toBalanceDelta(0, 1000),
            toBalanceDelta(1000, 1000),
            toBalanceDelta(-1000, -1000),
            toBalanceDelta(0, 0)
        ];
        for (uint256 i; i < invalidBuys.length; ++i) {
            for (uint256 side; side < 2; ++side) {
                bool buy = side == 0;
                BalanceDelta invalid = buy
                    ? invalidBuys[i]
                    : toBalanceDelta(-invalidBuys[i].amount0(), -invalidBuys[i].amount1());
                vm.prank(address(manager));
                vm.expectRevert(TidalHook.NoTrade.selector);
                hook.afterSwap(stranger, key, SwapParams(buy, -1000, Q96), invalid, "");
            }
        }
        assertEq(hook.totalFeesCollected(), 0);
        assertEq(hook.lastTick(), 0);
        _assertAccounting();
    }

    function test_dustInputWithNoOutputCannotBeCharged() public {
        _calm();
        bytes memory expected = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(TidalHook.NoTrade.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(expected);
        _swap(true, -1);
        vm.expectRevert(expected);
        _swap(false, -1);
        assertEq(hook.totalFeesCollected(), 0);
        _assertAccounting();
    }

    function test_zeroFeeAndFirstFeeWeiStillExecuteAndAllocate() public {
        _calm();
        BalanceDelta first = _swap(true, -333);
        assertGt(first.amount1(), 0);
        assertEq(hook.totalFeesCollected(), 0);
        // Clear the one-tick movement caused by the first tiny buy.
        _calm();
        BalanceDelta second = _swap(true, -334);
        assertGt(second.amount1(), 0);
        assertEq(hook.totalFeesCollected(), 1);
        assertEq(hook.treasuryAccrued(), 0);
        assertEq(hook.buybackAccrued(), 1);
        _assertAccounting();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_repeatedBuySellRoundTripsCannotCreateETH(uint96 raw, uint8 rawCycles, uint8 age)
        public
    {
        uint256 amount = bound(raw, 1000, 5 ether);
        uint256 cycles = bound(rawCycles, 1, 8);
        vm.roll(hook.launchBlock() + bound(age, 0, 25));
        uint256 originalETH = address(this).balance;
        uint256 originalTokens = token.balanceOf(address(this));
        for (uint256 i; i < cycles; ++i) {
            uint256 beforeETH = address(this).balance;
            BalanceDelta bought = _swap(true, -int256(amount));
            assertGt(bought.amount1(), 0);
            _swap(false, -int256(bought.amount1()));
            assertLt(address(this).balance, beforeETH, "round trip creates value");
            assertEq(token.balanceOf(address(this)), originalTokens);
        }
        assertLt(address(this).balance, originalETH);
        _assertAccounting();
    }
}
