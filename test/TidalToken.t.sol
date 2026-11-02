// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TidalToken} from "../src/TidalToken.sol";

contract TidalTokenTest is Test {
    TidalToken token;
    address alice;
    address bob;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        token = new TidalToken();
    }

    function test_launchSupplyAndMetadata() public view {
        assertEq(token.name(), "Tidal");
        assertEq(token.symbol(), "TIDAL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferAndAllowanceConserve(uint128 raw) public {
        uint256 amount = bound(raw, 0, 1e27);
        assertTrue(token.transfer(alice, amount));
        vm.prank(alice);
        token.approve(bob, amount);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(bob), token.totalSupply());
    }

    function test_holderCanBurnOnlyOwnBalance() public {
        token.transfer(alice, 100 ether);
        vm.prank(bob);
        vm.expectRevert();
        token.burn(1);
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1);
        vm.prank(alice);
        token.burn(40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.totalSupply(), 1e27 - 40 ether);
    }

    function test_transferToZeroAndOverspendRefused() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(bob);
        vm.expectRevert();
        token.transfer(alice, 1);
    }

    function test_noMintOrAdminEntrypoints() public {
        string[5] memory signatures = [
            "mint(address,uint256)",
            "initialize(address)",
            "pause()",
            "upgradeTo(address)",
            "burnFrom(address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], bob, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
