// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract VolatilityTest is Fixture {
    function test_launchSurchargeEveryBlockAndBoundary() public {
        uint256 opened = hook.launchBlock();
        for (uint256 age; age <= 25; ++age) {
            vm.roll(opened + age);
            uint256 expected = age < 20 ? (20 - age) * 10_000 : 0;
            assertEq(hook.launchFeePips(), expected);
            assertEq(hook.quoteFeePips(), 3000 + expected);
        }
    }

    function test_volatilePriceRaisesFeeThenDecaysEachBlock() public {
        _calm();
        assertEq(hook.dynamicFeePips(), 3000);
        _swap(true, -5 ether);
        int256 tick = hook.lastTick();
        uint256 movement = uint256(tick < 0 ? -tick : tick);
        assertGt(movement, 0);
        assertLt(movement, 340);
        assertEq(hook.dynamicFeePips(), 3000 + movement * 50);
        uint256 changedAt = block.number;
        uint256 previous = hook.dynamicFeePips();
        for (uint256 age = 1; age <= 8; ++age) {
            vm.roll(changedAt + age);
            uint256 current = hook.dynamicFeePips();
            assertEq(current, 3000 + movement * (8 - age) * 50 / 8);
            assertLt(current, previous);
            previous = current;
        }
        assertEq(hook.dynamicFeePips(), 3000);
    }

    function test_largeShockCapsFeeAndIdleMarketResets() public {
        _calm();
        _swap(true, -50 ether);
        assertEq(hook.dynamicFeePips(), 20_000);
        uint256 afterShock = block.number;
        vm.roll(afterShock + 4);
        assertEq(hook.dynamicFeePips(), 11_500);
        vm.roll(afterShock + 8);
        assertEq(hook.dynamicFeePips(), 3000);
        _swap(false, -0.001 ether);
        assertLt(hook.dynamicFeePips(), 3500, "old history must not reappear on ring reuse");
    }

    function test_swapPaysPriorSignalAndNextSwapPaysNewSignal() public {
        _calm();
        _swap(true, -50 ether);
        assertEq(hook.totalFeesCollected(), 50 ether * 3000 / D);
        uint256 collected = hook.totalFeesCollected();
        _swap(true, -1 ether);
        assertEq(hook.totalFeesCollected() - collected, 1 ether * 20_000 / D);
    }

    function test_multipleBlockObservationsAgeIndependently() public {
        _calm();
        _swap(true, -1 ether);
        uint256 firstAt = block.number;
        (, uint64 firstMove) = hook.observations(firstAt % 8);
        vm.roll(firstAt + 3);
        _swap(false, -1 ether);
        (, uint64 secondMove) = hook.observations(block.number % 8);
        assertEq(hook.dynamicFeePips(), 3000 + (uint256(firstMove) * 5 + uint256(secondMove) * 8) * 50 / 8);
        vm.roll(firstAt + 8);
        assertEq(hook.dynamicFeePips(), 3000 + uint256(secondMove) * 3 * 50 / 8);
        vm.roll(firstAt + 11);
        assertEq(hook.dynamicFeePips(), 3000);
    }

    function test_sameBlockRoundTripsAccumulateAbsoluteMovement() public {
        _calm();
        BalanceDelta bought = _swap(true, -5 ether);
        uint256 firstRate = hook.dynamicFeePips();
        _swap(false, -int256(bought.amount1()));
        assertGt(hook.dynamicFeePips(), firstRate);
        _assertAccounting();
    }

    function test_totalLaunchAndVolatilityFeeNeverExceeds22Percent() public {
        _swap(true, -50 ether);
        assertEq(hook.quoteFeePips(), 220_000);
        vm.roll(hook.launchBlock() + 19);
        _swap(true, -50 ether);
        assertEq(hook.quoteFeePips(), 30_000);
        vm.roll(hook.launchBlock() + 20);
        assertLe(hook.quoteFeePips(), 20_000);
        assertEq(hook.launchFeePips(), 0);
    }

    function testFuzz_launchDecay(uint64 age) public {
        vm.roll(hook.launchBlock() + age);
        uint256 expected = age >= 20 ? 0 : (20 - uint256(age)) * 10_000;
        assertEq(hook.launchFeePips(), expected);
        assertEq(hook.dynamicFeePips(), 3000);
    }
}
