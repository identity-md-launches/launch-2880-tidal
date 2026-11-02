// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {TidalHook} from "../src/TidalHook.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract RejectingTreasury {
    receive() external payable {
        revert("no ETH");
    }
}

contract ReenteringTreasury {
    TidalHook public hook;
    bool public attempted;
    bool public reentered;
    uint256 public received;

    constructor(TidalHook hook_) {
        hook = hook_;
    }

    receive() external payable {
        received += msg.value;
        attempted = true;
        (reentered,) = address(hook).call(abi.encodeCall(TidalHook.claimTreasury, ()));
    }
}

contract BuybackTreasuryTest is Fixture {
    using StateLibrary for IPoolManager;

    function test_claimPaysConfiguredTreasuryNotCaller() public {
        _swap(true, -1 ether);
        uint256 owed = hook.treasuryAccrued();
        uint256 buybackBefore = hook.buybackAccrued();
        vm.prank(stranger);
        assertEq(hook.claimTreasury(), owed);
        assertEq(creator.balance, owed);
        assertEq(stranger.balance, 0);
        assertEq(hook.buybackAccrued(), buybackBefore);
        vm.expectRevert(TidalHook.NothingToClaim.selector);
        hook.claimTreasury();
        _assertAccounting();
    }

    function test_rejectingTreasuryDoesNotBlockSwapsOrBurns() public {
        RejectingTreasury receiver = new RejectingTreasury();
        vm.prank(creator);
        hook.setTreasury(address(receiver));
        _swap(true, -1 ether);
        uint256 owed = hook.treasuryAccrued();
        vm.expectRevert(TidalHook.NativeTransferFailed.selector);
        hook.claimTreasury();
        assertEq(hook.treasuryAccrued(), owed);
        assertEq(hook.totalTreasuryPaid(), 0);
        _swap(false, -1 ether);
        _buybackAll();
        vm.prank(creator);
        hook.setTreasury(creator);
        hook.claimTreasury();
        _assertAccounting();
    }

    function test_treasuryReentrancyCannotDoubleClaim() public {
        ReenteringTreasury receiver = new ReenteringTreasury(hook);
        vm.prank(creator);
        hook.setTreasury(address(receiver));
        _swap(true, -1 ether);
        uint256 owed = hook.treasuryAccrued();
        hook.claimTreasury();
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(receiver.received(), owed);
        assertEq(hook.treasuryAccrued(), 0);
        _assertAccounting();
    }

    function test_buybackSpendsOnlyAllocationAndReallyBurns() public {
        _swap(true, -5 ether);
        uint256 treasuryBefore = hook.treasuryAccrued();
        uint256 budget = hook.buybackAccrued();
        uint256 supply = token.totalSupply();
        uint256 fees = hook.totalFeesCollected();
        (uint256 spent, uint256 burned) = _buybackAll();
        assertEq(spent, budget);
        assertGt(burned, 0);
        assertEq(supply - token.totalSupply(), burned);
        assertEq(hook.buybackAccrued(), 0);
        assertEq(hook.treasuryAccrued(), treasuryBefore);
        assertEq(hook.totalFeesCollected(), fees, "no recursive hook charge on buyback");
        (, int24 actualTick,,) = manager.getSlot0(hook.poolId());
        assertEq(hook.lastTick(), actualTick, "self swap still updates volatility");
        _assertAccounting();
    }

    function test_freshClaimsCanFundBuybackWithoutRedemption() public {
        _fresh();
        _swap(true, -5 ether);
        assertEq(address(hook).balance, 0);
        uint256 claims = hook.claimsOutstanding();
        (uint256 spent,) = _buybackAll();
        assertEq(hook.claimsOutstanding(), claims - spent);
        assertEq(address(hook).balance, 0);
        hook.claimTreasury();
        assertEq(hook.claimsOutstanding(), 0);
        _assertAccounting();
    }

    function test_claimTreasuryAutomaticallyRedeemsFreshClaims() public {
        _fresh();
        _swap(true, -1 ether);
        uint256 totalClaims = hook.claimsOutstanding();
        uint256 treasury = hook.treasuryAccrued();
        hook.claimTreasury();
        assertEq(creator.balance, treasury);
        assertEq(hook.claimsOutstanding(), totalClaims - treasury);
        _assertAccounting();
    }

    function test_anyoneCanRedeemClaimsToHookOnly() public {
        _fresh();
        _swap(true, -1 ether);
        uint256 amount = hook.claimsOutstanding();
        vm.prank(stranger);
        hook.redeemClaims(amount);
        assertEq(hook.claimsOutstanding(), 0);
        assertEq(address(hook).balance, amount);
        assertEq(stranger.balance, 0);
        vm.expectRevert(TidalHook.InvalidAmount.selector);
        hook.redeemClaims(1);
        vm.expectRevert(TidalHook.InvalidAmount.selector);
        hook.redeemClaims(0);
        _assertAccounting();
    }

    function test_failedRedemptionRollsBackAndRemainsRetryable() public {
        _fresh();
        _swap(true, -1 ether);
        uint256 amount = hook.claimsOutstanding();
        uint256 balance = address(manager).balance;
        vm.deal(address(manager), 0);
        vm.expectRevert();
        hook.redeemClaims(amount);
        assertEq(hook.claimsOutstanding(), amount);
        assertEq(manager.balanceOf(address(hook), 0), amount);
        vm.deal(address(manager), balance);
        hook.redeemClaims(amount);
        _assertAccounting();
    }

    function test_partialBuybackKeepsUnusedBudget() public {
        _swap(true, -50 ether);
        uint256 budget = hook.buybackAccrued();
        (, int24 tick,,) = manager.getSlot0(hook.poolId());
        vm.prank(creator);
        (uint256 spent, uint256 burned) =
            hook.executeBuyback(budget, 1, TickMath.getSqrtPriceAtTick(tick - 1), block.timestamp);
        assertGt(spent, 0);
        assertLt(spent, budget);
        assertGt(burned, 0);
        assertEq(hook.buybackAccrued(), budget - spent);
        _assertAccounting();
    }

    function test_buybackOutputLimitFailureRollsBackEverything() public {
        _swap(true, -1 ether);
        uint256 budget = hook.buybackAccrued();
        uint256 supply = token.totalSupply();
        (uint160 price,,,) = manager.getSlot0(hook.poolId());
        vm.prank(creator);
        vm.expectRevert(TidalHook.TooLittleReceived.selector);
        hook.executeBuyback(budget, 1e27, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        (uint160 afterPrice,,,) = manager.getSlot0(hook.poolId());
        assertEq(afterPrice, price);
        assertEq(hook.buybackAccrued(), budget);
        assertEq(token.totalSupply(), supply);
        assertEq(hook.totalBuybackSpent(), 0);
        _buybackAll();
        _assertAccounting();
    }

    function test_buybackInvalidInputsAndUnauthorizedCaller() public {
        _swap(true, -1 ether);
        uint256 budget = hook.buybackAccrued();
        (uint160 price,,,) = manager.getSlot0(hook.poolId());
        vm.prank(stranger);
        vm.expectRevert();
        hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        vm.startPrank(creator);
        vm.expectRevert(TidalHook.InvalidAmount.selector);
        hook.executeBuyback(budget + 1, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        vm.expectRevert(TidalHook.InvalidAmount.selector);
        hook.executeBuyback(0, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        vm.expectRevert(TidalHook.InvalidBuybackBounds.selector);
        hook.executeBuyback(budget, 0, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        vm.expectRevert(TidalHook.InvalidBuybackBounds.selector);
        hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp - 1);
        vm.expectRevert(TidalHook.InvalidBuybackBounds.selector);
        hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp + 1801);
        vm.expectRevert(TidalHook.InvalidBuybackBounds.selector);
        hook.executeBuyback(budget, 1, price, block.timestamp);
        vm.expectRevert(TidalHook.InvalidBuybackBounds.selector);
        hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE, block.timestamp);
        vm.stopPrank();
        _assertAccounting();
    }

    function test_oddWeiSplitCarriesAcrossSwaps() public {
        _calm();
        _swap(true, -1000);
        assertEq(hook.totalFeesCollected(), 3);
        assertEq(hook.treasuryAccrued(), 1);
        assertEq(hook.buybackAccrued(), 2);
        _calm();
        _swap(true, -1000);
        assertEq(hook.totalFeesCollected(), 6);
        assertEq(hook.treasuryAccrued(), 3);
        assertEq(hook.buybackAccrued(), 3);
        _assertAccounting();
    }

    function testFuzz_splitRemainsExactAcrossClaimsAndBurns(uint96 raw) public {
        uint256 amount = bound(raw, 1e12, 10 ether);
        _swap(true, -int256(amount));
        hook.claimTreasury();
        _buybackAll();
        _swap(false, -int256(amount));
        _assertAccounting();
        hook.claimTreasury();
        _buybackAll();
        _assertAccounting();
    }

    function _buybackAll() internal returns (uint256 spent, uint256 burned) {
        uint256 amount = hook.buybackAccrued();
        vm.prank(creator);
        return hook.executeBuyback(amount, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp + 60);
    }
}
