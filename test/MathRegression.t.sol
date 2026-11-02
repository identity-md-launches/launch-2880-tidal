// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract MathRegressionTest is Test {
    function test_everySingleBitAndAdjacentValues() public pure {
        for (uint256 i; i < 256; ++i) {
            uint256 value = uint256(1) << i;
            assertEq(BitMath.mostSignificantBit(value), i);
            assertEq(BitMath.leastSignificantBit(value), i);
            if (i > 0) {
                assertEq(BitMath.mostSignificantBit(value - 1), i - 1);
                assertEq(BitMath.leastSignificantBit(value - 1), 0);
                assertEq(BitMath.mostSignificantBit(value + 1), i);
                assertEq(BitMath.leastSignificantBit(value + 1), 0);
            }
        }
        assertEq(BitMath.mostSignificantBit(type(uint256).max), 255);
        assertEq(BitMath.leastSignificantBit(type(uint256).max), 0);
    }

    function testFuzz_bitIndicesMatchSlowReference(uint256 x) public pure {
        if (x == 0) x = 1;
        uint256 highest;
        uint256 lowest;
        uint256 v = x;
        while (v > 1) {
            v >>= 1;
            ++highest;
        }
        v = x;
        while (v & 1 == 0) {
            v >>= 1;
            ++lowest;
        }
        assertEq(BitMath.mostSignificantBit(x), highest);
        assertEq(BitMath.leastSignificantBit(x), lowest);
    }

    function test_zeroBitSearchReverts() public {
        vm.expectRevert();
        this.msb(0);
        vm.expectRevert();
        this.lsb(0);
    }

    function msb(uint256 x) external pure returns (uint8) {
        return BitMath.mostSignificantBit(x);
    }

    function lsb(uint256 x) external pure returns (uint8) {
        return BitMath.leastSignificantBit(x);
    }

    function testFuzz_fullPrecisionInverseSeed(uint256 a, uint128 rawB, uint128 rawD) public pure {
        uint256 b = rawB;
        uint256 d = rawD;
        if (d < b) (b, d) = (d, b);
        if (d == 0) d = 1;
        // Independent quotient/remainder decomposition. Both products fit: b <= d <= uint128.max.
        uint256 expected = (a / d) * b + ((a % d) * b) / d;
        assertEq(FullMath.mulDiv(a, b, d), expected);
        uint256 up = expected + (mulmod(a, b, d) > 0 ? 1 : 0);
        assertEq(FullMath.mulDivRoundingUp(a, b, d), up);
    }

    function test_fullPrecisionExtremeProductAndFailures() public {
        uint256 m = type(uint256).max;
        assertEq(FullMath.mulDiv(m, m, m), m);
        assertEq(FullMath.mulDiv(m, m - 1, m), m - 1);
        assertEq(FullMath.mulDiv(uint256(1) << 255, 2, 2), uint256(1) << 255);
        vm.expectRevert();
        this.mulDiv(1, 1, 0);
        vm.expectRevert();
        this.mulDiv(m, m, 1);
    }

    function testFuzz_fullWidthDenominatorCancellation(uint256 x, uint256 denominator) public pure {
        if (denominator == 0) denominator = 1;
        assertEq(FullMath.mulDiv(x, denominator, denominator), x);
    }

    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, d);
    }

    function testFuzz_tickMathRoundTrip(int24 raw) public pure {
        int24 tick = int24(bound(int256(raw), TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        assertEq(TickMath.getTickAtSqrtPrice(price), tick);
    }
}
