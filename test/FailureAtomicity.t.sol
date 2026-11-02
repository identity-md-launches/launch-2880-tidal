// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {HookState} from "./helpers/HookState.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {TidalHook} from "src/TidalHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

contract RefusingPayout {
    receive() external payable {
        revert("reject payout");
    }
}

/// @dev The receiver is also owner, so access control alone cannot explain failed reentry.
contract OwnerTreasuryProbe {
    TidalHook private immutable hook;
    bool public checked;
    uint256 public received;
    address private immutable controller;

    constructor(TidalHook hook_) {
        hook = hook_;
        controller = msg.sender;
    }

    function acceptOwnership() external {
        require(msg.sender == controller);
        hook.acceptOwnership();
    }

    receive() external payable {
        received += msg.value;
        _guarded(abi.encodeCall(TidalHook.claimTreasury, ()));
        _guarded(abi.encodeCall(TidalHook.redeemClaims, (1)));
        _guarded(abi.encodeCall(TidalHook.setTreasury, (controller)));
        _guarded(
            abi.encodeCall(
                TidalHook.executeBuyback,
                (hook.buybackAccrued(), 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp)
            )
        );
        checked = true;
    }

    function _guarded(bytes memory data) private {
        (bool ok, bytes memory reason) = address(hook).call(data);
        require(!ok, "reentrant action succeeded");
        require(
            keccak256(reason)
                == keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)),
            "reentry rejected for unrelated reason"
        );
    }
}

contract FailureAtomicityTest is Fixture {
    function test_rejectedPayoutRestoresRedeemedClaimsAndObservationHistory() public {
        _fresh();
        _swap(true, -5 ether);
        RefusingPayout receiver = new RefusingPayout();
        vm.prank(creator);
        hook.setTreasury(address(receiver));
        bytes32 beforeState = HookState.digest(hook);
        uint256 claims = hook.claimsOutstanding();
        uint256 owed = hook.treasuryAccrued();
        vm.expectRevert(TidalHook.NativeTransferFailed.selector);
        hook.claimTreasury();
        assertEq(HookState.digest(hook), beforeState, "revert must restore the claim burn and ETH take");
        assertEq(address(receiver).balance, 0);
        vm.prank(creator);
        hook.setTreasury(creator);
        assertEq(hook.claimTreasury(), owed);
        assertEq(creator.balance, owed);
        assertEq(hook.claimsOutstanding(), claims - owed);
        _assertAccounting();
    }

    function test_ownerTreasuryCannotReenterAnyGuardedFundOperation() public {
        _swap(true, -5 ether);
        OwnerTreasuryProbe receiver = new OwnerTreasuryProbe(hook);
        vm.startPrank(creator);
        hook.setTreasury(address(receiver));
        hook.transferOwnership(address(receiver));
        vm.stopPrank();
        receiver.acceptOwnership();
        uint256 owed = hook.treasuryAccrued();
        uint256 allocation = hook.buybackAccrued();
        vm.prank(stranger);
        hook.claimTreasury();
        assertTrue(receiver.checked());
        assertEq(receiver.received(), owed);
        assertEq(hook.treasury(), address(receiver));
        assertEq(hook.buybackAccrued(), allocation);
        assertEq(hook.totalBuybackSpent(), 0);
        _assertAccounting();
    }

    function test_underfundedRouterRollsBackClaimMintAndCanRetry() public {
        _fresh();
        _assertUnderfundedSwapAtomic();
    }

    function test_underfundedRouterRollsBackDirectFeeAndCanRetry() public {
        _assertUnderfundedSwapAtomic();
    }

    function _assertUnderfundedSwapAtomic() private {
        bytes32 beforeState = HookState.digest(hook);
        uint256 ethBefore = address(this).balance;
        uint256 routerETH = address(router).balance;
        uint256 routerTokens = token.balanceOf(address(router));
        uint256 tokensBefore = token.balanceOf(address(this));
        vm.expectRevert(TestRouter.BudgetExceeded.selector);
        router.swap{value: 1 ether - 1}(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), 0);
        assertEq(HookState.digest(hook), beforeState);
        assertEq(address(this).balance, ethBefore);
        assertEq(token.balanceOf(address(this)), tokensBefore);
        assertEq(address(router).balance, routerETH);
        assertEq(token.balanceOf(address(router)), routerTokens);
        _swap(true, -1 ether);
        assertGt(hook.totalFeesCollected(), 0);
        _assertAccounting();
    }

    function test_nativeSpecifiedPartialFillsHavePreciseErrorAndRollback() public {
        _swap(true, -1 ether);
        _calm();
        // Return near the initial price with a sell so both tight limits are on the valid side.
        _swap(false, -1 ether);
        bytes32 beforeState = HookState.digest(hook);
        bytes memory expected = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(TidalHook.NativeSpecifiedNotFilled.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(expected);
        router.swap{value: 50 ether}(key, SwapParams(true, -50 ether, TickMath.getSqrtPriceAtTick(-10)), 0);
        assertEq(HookState.digest(hook), beforeState);
        uint256 allowanceBefore = token.allowance(address(this), address(router));
        vm.expectRevert(expected);
        router.swap(key, SwapParams(false, 50 ether, TickMath.getSqrtPriceAtTick(10)), 100 ether);
        assertEq(HookState.digest(hook), beforeState);
        assertEq(
            token.allowance(address(this), address(router)), allowanceBefore, "failed pull restores allowance"
        );
    }

    function test_buybackSlippageRollsBackWithClaimsOnly() public {
        _fresh();
        _swap(true, -5 ether);
        assertEq(address(hook).balance, 0);
        _assertBuybackSlippageAtomic();
    }

    function test_buybackSlippageRollsBackWithCashAndClaims() public {
        _fresh();
        _swap(true, -5 ether);
        hook.redeemClaims(hook.claimsOutstanding() * 3 / 4);
        assertGt(address(hook).balance, 0);
        assertGt(hook.claimsOutstanding(), 0);
        _assertBuybackSlippageAtomic();
    }

    function _assertBuybackSlippageAtomic() private {
        uint256 budget = hook.buybackAccrued();
        bytes32 beforeState = HookState.digest(hook);
        uint256 impossibleOutput = token.totalSupply();
        vm.prank(creator);
        vm.expectRevert(TidalHook.TooLittleReceived.selector);
        hook.executeBuyback(budget, impossibleOutput, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        assertEq(HookState.digest(hook), beforeState);
        vm.prank(address(manager));
        vm.expectRevert(TidalHook.InvalidUnlock.selector);
        hook.unlockCallback(abi.encode(budget, 1, TickMath.MIN_SQRT_PRICE + 1));
        vm.prank(creator);
        (uint256 spent, uint256 burned) =
            hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp + 1800);
        assertEq(spent, budget);
        assertGt(burned, 0);
        _assertAccounting();
    }

    function test_buybackWithoutLiquidityPreservesBudgetAndCanRetry() public {
        _swap(true, -5 ether);
        router.modify(key, -60000, 60000, -1000 ether);
        uint256 budget = hook.buybackAccrued();
        bytes32 beforeState = HookState.digest(hook);
        vm.prank(creator);
        vm.expectRevert(TidalHook.NoTrade.selector);
        hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        assertEq(HookState.digest(hook), beforeState);
        router.modify(key, -60000, 60000, 1000 ether);
        vm.prank(creator);
        (uint256 spent, uint256 burned) =
            hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        assertEq(spent, budget);
        assertGt(burned, 0);
        _assertAccounting();
    }

    function test_cancelledAndReplacedNomineesCannotTakeControlOfAccruedFunds() public {
        _swap(true, -5 ether);
        address successor = makeAddr("successor");
        vm.startPrank(creator);
        hook.transferOwnership(stranger);
        hook.transferOwnership(address(0));
        vm.stopPrank();
        bytes32 beforeState = HookState.digest(hook);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.acceptOwnership();
        assertEq(HookState.digest(hook), beforeState);
        vm.startPrank(creator);
        hook.transferOwnership(stranger);
        hook.transferOwnership(successor);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        hook.acceptOwnership();
        vm.prank(successor);
        hook.acceptOwnership();
        assertEq(hook.pendingOwner(), address(0));
        assertEq(hook.treasury(), creator);
        uint256 budget = hook.buybackAccrued();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        vm.prank(successor);
        hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        _assertAccounting();
    }

    function test_elapsedSecondsCannotExpireLaunchOrVolatilityBlocks() public {
        _swap(true, -50 ether);
        uint256 at = block.number;
        uint256 launchFee = hook.launchFeePips();
        uint256 dynamicFee = hook.dynamicFeePips();
        vm.warp(block.timestamp + 365 days);
        assertEq(block.number, at);
        assertEq(hook.launchFeePips(), launchFee);
        assertEq(hook.dynamicFeePips(), dynamicFee);
        vm.roll(at + 20);
        assertEq(hook.quoteFeePips(), 3000);
    }

    function test_nativeReceiveRejectsNonManagerWithoutAcceptingValue() public {
        bytes32 beforeState = HookState.digest(hook);
        (bool ok, bytes memory reason) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(TidalHook.OnlyPoolManager.selector));
        assertEq(HookState.digest(hook), beforeState);
    }
}
