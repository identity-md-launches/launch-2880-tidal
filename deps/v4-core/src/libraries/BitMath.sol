// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title BitMath
/// @notice Binary search for bit indices, with explicit Solidity shift operands.
/// @dev Local replacement for the upstream assembly lookup; see deps/PATCHES.md.
library BitMath {
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);
        if (x >> 128 > 0) {
            x >>= 128;
            r += 128;
        }
        if (x >> 64 > 0) {
            x >>= 64;
            r += 64;
        }
        if (x >> 32 > 0) {
            x >>= 32;
            r += 32;
        }
        if (x >> 16 > 0) {
            x >>= 16;
            r += 16;
        }
        if (x >> 8 > 0) {
            x >>= 8;
            r += 8;
        }
        if (x >> 4 > 0) {
            x >>= 4;
            r += 4;
        }
        if (x >> 2 > 0) {
            x >>= 2;
            r += 2;
        }
        if (x >> 1 > 0) r += 1;
    }

    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);
        if (x & type(uint128).max == 0) {
            x >>= 128;
            r += 128;
        }
        if (x & type(uint64).max == 0) {
            x >>= 64;
            r += 64;
        }
        if (x & type(uint32).max == 0) {
            x >>= 32;
            r += 32;
        }
        if (x & type(uint16).max == 0) {
            x >>= 16;
            r += 16;
        }
        if (x & type(uint8).max == 0) {
            x >>= 8;
            r += 8;
        }
        if (x & 0x0f == 0) {
            x >>= 4;
            r += 4;
        }
        if (x & 0x03 == 0) {
            x >>= 2;
            r += 2;
        }
        if (x & 0x01 == 0) r += 1;
    }
}
