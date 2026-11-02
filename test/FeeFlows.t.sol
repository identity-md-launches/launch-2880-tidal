// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract FeeFlowsTest is Fixture {
    using StateLibrary for IPoolManager;

    function test_buyExactInputFundedAndFresh() public {
        _checkBuyInput();
        _fresh();
        _checkBuyInput();
        assertGt(hook.claimsOutstanding(), 0);
        assertEq(address(hook).balance, 0);
    }

    function test_buyExactOutputFundedAndFresh() public {
        _checkBuyOutput();
        _fresh();
        _checkBuyOutput();
        assertGt(hook.claimsOutstanding(), 0);
    }

    function test_sellExactInputFundedAndFresh() public {
        _checkSellInput();
        _fresh();
        _swap(true, -10 ether);
        _checkSellInput();
    }

    function test_sellExactOutputFundedAndFresh() public {
        _checkSellOutput();
        _fresh();
        _swap(true, -10 ether);
        _checkSellOutput();
    }

    function _checkBuyInput() internal {
        uint256 rate = hook.quoteFeePips();
        uint256 beforeFees = hook.totalFeesCollected();
        uint256 beforeEth = address(this).balance;
        uint256 beforeTokens = token.balanceOf(address(this));
        BalanceDelta delta = _swap(true, -1 ether);
        uint256 fee = hook.totalFeesCollected() - beforeFees;
        assertEq(delta.amount0(), -1 ether);
        assertGt(delta.amount1(), 0);
        assertEq(fee, 1 ether * rate / D);
        assertEq(beforeEth - address(this).balance, 1 ether);
        assertEq(token.balanceOf(address(this)) - beforeTokens, uint256(uint128(delta.amount1())));
        _assertAccounting();
    }

    function _checkBuyOutput() internal {
        uint256 rate = hook.quoteFeePips();
        uint256 beforeFees = hook.totalFeesCollected();
        BalanceDelta delta = _swap(true, 1 ether);
        uint256 fee = hook.totalFeesCollected() - beforeFees;
        uint256 rawNative = uint256(-int256(delta.amount0())) - fee;
        assertEq(delta.amount1(), 1 ether);
        assertEq(fee, _gross(rawNative, rate));
        _assertAccounting();
    }

    function _checkSellInput() internal {
        uint256 rate = hook.quoteFeePips();
        uint256 beforeFees = hook.totalFeesCollected();
        BalanceDelta delta = _swap(false, -1 ether);
        uint256 fee = hook.totalFeesCollected() - beforeFees;
        uint256 rawNative = uint256(uint128(delta.amount0())) + fee;
        assertEq(delta.amount1(), -1 ether);
        assertEq(fee, rawNative * rate / D);
        _assertAccounting();
    }

    function _checkSellOutput() internal {
        uint256 rate = hook.quoteFeePips();
        uint256 beforeFees = hook.totalFeesCollected();
        BalanceDelta delta = _swap(false, 1 ether);
        uint256 fee = hook.totalFeesCollected() - beforeFees;
        assertEq(delta.amount0(), 1 ether);
        assertLt(delta.amount1(), 0);
        assertEq(fee, _gross(1 ether, rate));
        _assertAccounting();
    }

    function test_partialSellExactInputChargesOnlyFilledETH() public {
        _calm();
        uint256 rate = hook.quoteFeePips();
        BalanceDelta delta =
            router.swap(key, SwapParams(false, -50 ether, TickMath.getSqrtPriceAtTick(10)), 50 ether);
        uint256 fee = hook.totalFeesCollected();
        assertLt(uint256(-int256(delta.amount1())), 50 ether);
        assertGt(delta.amount0(), 0);
        assertEq(fee, (uint256(uint128(delta.amount0())) + fee) * rate / D);
        _assertAccounting();
    }

    function test_partialBuyExactOutputChargesOnlyActualInput() public {
        _calm();
        BalanceDelta delta = router.swap{value: 100 ether}(
            key, SwapParams(true, 50 ether, TickMath.getSqrtPriceAtTick(-10)), 0
        );
        assertGt(delta.amount1(), 0);
        assertLt(delta.amount1(), 50 ether);
        uint256 fee = hook.totalFeesCollected();
        assertEq(fee, _gross(uint256(-int256(delta.amount0())) - fee, 3000));
        _assertAccounting();
    }

    function test_partialNativeSpecifiedBuyRevertsWithoutCharge() public {
        vm.expectRevert();
        router.swap{value: 50 ether}(key, SwapParams(true, -50 ether, TickMath.getSqrtPriceAtTick(-10)), 0);
        assertEq(hook.totalFeesCollected(), 0);
        _assertAccounting();
    }

    function test_partialNativeSpecifiedSellRevertsWithoutCharge() public {
        vm.expectRevert();
        router.swap(key, SwapParams(false, 50 ether, TickMath.getSqrtPriceAtTick(10)), 100 ether);
        assertEq(hook.totalFeesCollected(), 0);
        _assertAccounting();
    }

    function test_factoryCanCollectAndWithdrawLiquidity() public {
        _swap(true, -1 ether);
        _swap(false, -1 ether);
        uint256 fees = hook.totalFeesCollected();
        BalanceDelta collected = router.modify(key, -60000, 60000, 0);
        assertGt(collected.amount0(), 0);
        assertGt(collected.amount1(), 0);
        assertEq(hook.totalFeesCollected(), fees);
        BalanceDelta removed = router.modify(key, -60000, 60000, -1000 ether);
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        _assertAccounting();
    }

    function test_noLiquidityDoesNotCollectFee() public {
        router.modify(key, -60000, 60000, -1000 ether);
        vm.expectRevert();
        _swap(true, -1 ether);
        assertEq(hook.totalFeesCollected(), 0);
    }

    function testFuzz_fourSwapModesConserve(uint96 raw, bool buy, bool exactInput, uint8 age) public {
        uint256 amount = bound(raw, 1e8, 5 ether);
        vm.roll(hook.launchBlock() + bound(age, 0, 50));
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        uint256 rate = hook.quoteFeePips();
        BalanceDelta delta = _swap(buy, specified);
        uint256 fee = hook.totalFeesCollected();
        if (buy && exactInput) {
            assertEq(fee, amount * rate / D);
            assertEq(delta.amount0(), -int256(amount));
        } else if (!buy && !exactInput) {
            assertEq(fee, _gross(amount, rate));
            assertEq(delta.amount0(), int256(amount));
        } else if (buy) {
            assertEq(fee, _gross(uint256(-int256(delta.amount0())) - fee, rate));
            assertEq(delta.amount1(), int256(amount));
        } else {
            assertEq(fee, (uint256(uint128(delta.amount0())) + fee) * rate / D);
            assertEq(delta.amount1(), -int256(amount));
        }
        assertLe(rate, 220_000);
        _assertAccounting();
    }
}
