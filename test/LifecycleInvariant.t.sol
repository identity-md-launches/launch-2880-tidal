// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {HookState} from "./helpers/HookState.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {TidalHook} from "src/TidalHook.sol";
import {TidalToken} from "src/TidalToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract ForcedETH {
    constructor(address payable recipient) payable {
        selfdestruct(recipient);
    }
}

/// @dev Every unsolicited claim is backed with real native settlement in the same unlock.
contract ClaimDonation is IUnlockCallback {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(address recipient) external payable {
        manager.unlock(abi.encode(recipient, msg.value));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        manager.sync(Currency.wrap(address(0)));
        require(manager.settle{value: amount}() == amount);
        manager.mint(recipient, 0, amount);
        return "";
    }
}

contract LifecycleHandler is Test {
    using StateLibrary for IPoolManager;

    TidalHook public immutable hook;
    TidalToken public immutable token;
    IPoolManager public immutable manager;
    TestRouter public immutable router;
    ClaimDonation private immutable donor;
    PoolKey private key;
    address[3] public actors;
    address[4] public recipients;
    address public expectedOwner;
    address public expectedPendingOwner;
    address public expectedTreasury;
    uint256 public immutable openedAt;
    uint256 public ghostFees;
    uint256 public ghostPaid;
    uint256 public ghostSpent;
    uint256 public ghostBuybackBurns;
    uint256 public ghostHolderBurns;
    uint256 public ghostNativeDonations;
    uint256 public ghostClaimDonations;
    uint256 public ghostTokenDonations;
    uint256 public successfulSwaps;
    uint256 public successfulBuybacks;
    uint256 public successfulClaims;
    uint256 public successfulRedemptions;
    uint256 public rejectedCalls;
    // An absolute block-number map, unlike the hook's capped eight-slot ring buffer.
    // Inputs come from PoolManager prices, never from hook.lastTick or observations.
    mapping(uint256 => uint256) private observedMovement;
    int24 private recordedTick;

    constructor(TidalHook hook_, TestRouter router_, address creator_) {
        hook = hook_;
        token = hook_.token();
        manager = hook_.poolManager();
        router = router_;
        key = hook_.getPoolKey();
        donor = new ClaimDonation(manager);
        expectedOwner = creator_;
        expectedTreasury = creator_;
        recipients[0] = creator_;
        openedAt = hook_.launchBlock();
        // Bootstrap's real receipts, not the implementation's fee counter.
        ghostFees = address(hook_).balance + manager.balanceOf(address(hook_), 0);
        // The fixture opened at tick zero and made its first buy in this block.
        _recordMovement();
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string.concat("lifecycle trader ", vm.toString(i)));
            recipients[i + 1] = makeAddr(string.concat("lifecycle treasury ", vm.toString(i)));
            vm.prank(actors[i]);
            token.approve(address(router), type(uint256).max);
        }
    }

    function trade(uint8 actorSeed, uint96 raw, bool buy, bool exactInput) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(raw, 1e9, 0.1 ether);
        uint256 assetsBefore = _assets();
        uint256 ethBefore = actor.balance;
        uint256 tokensBefore = token.balanceOf(actor);
        uint256 supplyBefore = token.totalSupply();
        uint256 rate = hook.quoteFeePips();
        vm.prank(actor);
        BalanceDelta delta = router.swap{value: buy ? 1 ether : 0}(
            key,
            SwapParams(
                buy,
                exactInput ? -int256(amount) : int256(amount),
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            buy ? 0 : 1 ether
        );
        uint256 receipt = _assets() - assetsBefore;
        uint256 grossNative = buy ? ethBefore - actor.balance : actor.balance - ethBefore + receipt;
        if (buy && !exactInput) {
            assertGe(receipt * 1_000_000, grossNative * rate);
            assertLt((receipt - 1) * 1_000_000, grossNative * rate);
        } else if (!buy && !exactInput) {
            assertGe(receipt * (1_000_000 - rate), amount * rate);
            assertLt((receipt - 1) * (1_000_000 - rate), amount * rate);
        } else {
            assertLe(receipt * 1_000_000, grossNative * rate);
            assertGt((receipt + 1) * 1_000_000, grossNative * rate);
        }
        assertEq(int256(actor.balance) - int256(ethBefore), int256(delta.amount0()));
        assertEq(int256(token.balanceOf(actor)) - int256(tokensBefore), int256(delta.amount1()));
        assertEq(token.totalSupply(), supplyBefore, "ordinary swaps cannot burn or mint");
        if (exactInput) {
            assertEq(buy ? int256(delta.amount0()) : int256(delta.amount1()), -int256(amount));
        } else {
            assertEq(buy ? int256(delta.amount1()) : int256(delta.amount0()), int256(amount));
        }
        ghostFees += receipt;
        _recordMovement();
        ++successfulSwaps;
    }

    function advance(uint8 blocks_) external {
        uint256 n = bound(blocks_, 0, 20);
        uint256 rateBefore = hook.dynamicFeePips();
        vm.roll(block.number + n);
        vm.warp(block.timestamp + 12 * n);
        assertLe(hook.dynamicFeePips(), rateBefore, "idle market cannot increase fee");
        if (n >= 8) assertEq(hook.dynamicFeePips(), 3000);
    }

    function claim(uint8 callerSeed) external {
        uint256 owed = hook.treasuryAccrued();
        if (owed == 0) return;
        uint256 receivedBefore = expectedTreasury.balance;
        vm.prank(actors[callerSeed % 3]);
        uint256 paid = hook.claimTreasury();
        uint256 received = expectedTreasury.balance - receivedBefore;
        assertEq(received, owed);
        assertEq(paid, received);
        ghostPaid += received;
        ++successfulClaims;
    }

    function redeem(uint96 raw, uint8 callerSeed) external {
        uint256 claims = hook.claimsOutstanding();
        if (claims == 0) return;
        uint256 amount = bound(raw, 1, claims);
        uint256 actualClaims = manager.balanceOf(address(hook), 0);
        uint256 cash = address(hook).balance;
        address actor = actors[callerSeed % 3];
        uint256 callerETH = actor.balance;
        vm.prank(actor);
        hook.redeemClaims(amount);
        assertEq(manager.balanceOf(address(hook), 0), actualClaims - amount);
        assertEq(address(hook).balance, cash + amount);
        assertEq(actor.balance, callerETH);
        ++successfulRedemptions;
    }

    function buyback(uint16 fraction, bool full) external {
        uint256 budget = hook.buybackAccrued();
        if (budget < 1000) return;
        uint256 amount = full ? budget : budget * bound(fraction, 1, 10_000) / 10_000;
        if (amount < 1000) amount = budget;
        uint256 assetsBefore = _assets();
        uint256 supplyBefore = token.totalSupply();
        uint256 treasuryBefore = hook.treasuryAccrued();
        uint256 ownerETH = expectedOwner.balance;
        uint256 ownerTokens = token.balanceOf(expectedOwner);
        vm.prank(expectedOwner);
        (uint256 spent, uint256 burned) =
            hook.executeBuyback(amount, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp + 1800);
        uint256 actualSpent = assetsBefore - _assets();
        uint256 actualBurned = supplyBefore - token.totalSupply();
        assertEq(actualSpent, spent);
        assertEq(spent, amount);
        assertEq(actualBurned, burned);
        assertGt(burned, 0);
        assertEq(hook.treasuryAccrued(), treasuryBefore);
        assertEq(expectedOwner.balance, ownerETH);
        assertEq(token.balanceOf(expectedOwner), ownerTokens);
        ghostSpent += actualSpent;
        ghostBuybackBurns += actualBurned;
        _recordMovement();
        ++successfulBuybacks;
    }

    function nominate(uint8 actorSeed, bool cancel) external {
        address next = cancel ? address(0) : actors[actorSeed % 3];
        vm.prank(expectedOwner);
        hook.transferOwnership(next);
        expectedPendingOwner = next;
        assertEq(hook.owner(), expectedOwner, "nomination cannot change owner");
        assertEq(hook.treasury(), expectedTreasury);
    }

    function accept(uint8 actorSeed) external {
        address actor = actors[actorSeed % 3];
        if (actor != expectedPendingOwner) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
            hook.acceptOwnership();
            ++rejectedCalls;
            return;
        }
        vm.prank(actor);
        hook.acceptOwnership();
        expectedOwner = actor;
        expectedPendingOwner = address(0);
        assertEq(hook.treasury(), expectedTreasury, "ownership cannot redirect accrued fees");
    }

    function redirect(uint8 recipientSeed) external {
        expectedTreasury = recipients[recipientSeed % 4];
        vm.prank(expectedOwner);
        hook.setTreasury(expectedTreasury);
    }

    function donate(uint96 raw, uint8 kind, uint8 actorSeed) external {
        uint256 amount = bound(raw, 1, 0.1 ether);
        uint256 feesBefore = hook.totalFeesCollected();
        if (kind % 3 == 0) {
            new ForcedETH{value: amount}(payable(address(hook)));
            ghostNativeDonations += amount;
        } else if (kind % 3 == 1) {
            donor.donate{value: amount}(address(hook));
            ghostClaimDonations += amount;
        } else {
            vm.prank(actors[actorSeed % 3]);
            assertTrue(token.transfer(address(hook), amount));
            ghostTokenDonations += amount;
        }
        assertEq(hook.totalFeesCollected(), feesBefore, "unsolicited assets are not swap fees");
    }

    function holderBurn(uint96 raw, uint8 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(raw, 0, 0.1 ether);
        uint256 beforeBalance = token.balanceOf(actor);
        vm.prank(actor);
        token.burn(amount);
        assertEq(token.balanceOf(actor), beforeBalance - amount);
        ghostHolderBurns += amount;
    }

    function rejectedAction(uint8 choice, uint8 actorSeed) external {
        bytes32 beforeState = HookState.digest(hook);
        address actor = actors[actorSeed % 3];
        if (actor == expectedOwner) actor = actors[(actorSeed % 3 + 1) % 3];
        if (choice % 4 == 0) {
            uint256 amount = hook.claimsOutstanding() + 1;
            vm.prank(actor);
            vm.expectRevert(TidalHook.InvalidAmount.selector);
            hook.redeemClaims(amount);
        } else if (choice % 4 == 1) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
            hook.setTreasury(actor);
        } else if (choice % 4 == 2) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
            hook.executeBuyback(1, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        } else {
            vm.prank(expectedOwner);
            vm.expectRevert(TidalHook.RenounceDisabled.selector);
            hook.renounceOwnership();
        }
        assertEq(HookState.digest(hook), beforeState, "rejected action changed economic state");
        ++rejectedCalls;
    }

    function _assets() private view returns (uint256) {
        return address(hook).balance + manager.balanceOf(address(hook), 0);
    }

    function _recordMovement() private {
        (, int24 tick,,) = manager.getSlot0(hook.poolId());
        int256 difference = int256(tick) - recordedTick;
        observedMovement[block.number] += uint256(difference < 0 ? -difference : difference);
        recordedTick = tick;
    }

    function expectedDynamicFee() external view returns (uint256) {
        uint256 weighted;
        for (uint256 age; age < 8; ++age) {
            uint256 movement = observedMovement[block.number - age];
            weighted += (movement > 340 ? 340 : movement) * (8 - age);
        }
        uint256 premium = weighted * 50 / 8;
        return 3000 + (premium > 17_000 ? 17_000 : premium);
    }
}

/// @dev All assets come from initial funding and explicit, ghost-tracked donations; no mid-run deals.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LifecycleInvariantTest is Fixture {
    using StateLibrary for IPoolManager;
    LifecycleHandler private handler;

    function setUp() public override {
        creator = makeAddr("pool creator");
        stranger = makeAddr("stranger");
        _fresh();
        _swap(true, -80 ether);
        handler = new LifecycleHandler(hook, router, creator);
        vm.deal(address(handler), 100 ether);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            vm.deal(actor, 1000 ether);
            token.transfer(actor, 1000 ether);
        }
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = LifecycleHandler.trade.selector;
        selectors[1] = LifecycleHandler.advance.selector;
        selectors[2] = LifecycleHandler.claim.selector;
        selectors[3] = LifecycleHandler.redeem.selector;
        selectors[4] = LifecycleHandler.buyback.selector;
        selectors[5] = LifecycleHandler.nominate.selector;
        selectors[6] = LifecycleHandler.accept.selector;
        selectors[7] = LifecycleHandler.redirect.selector;
        selectors[8] = LifecycleHandler.donate.selector;
        selectors[9] = LifecycleHandler.holderBurn.selector;
        selectors[10] = LifecycleHandler.rejectedAction.selector;
        // Weight the swap path twice so claims and fees continue to be produced.
        selectors[11] = LifecycleHandler.trade.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_receiptsBackBothAllocationsDespiteDonations() public view {
        uint256 fees = handler.ghostFees();
        assertEq(hook.totalFeesCollected(), fees);
        assertEq(hook.treasuryAccrued() + handler.ghostPaid(), fees / 2);
        assertEq(hook.buybackAccrued() + handler.ghostSpent(), fees - fees / 2);
        assertEq(hook.totalTreasuryPaid(), handler.ghostPaid());
        assertEq(hook.totalBuybackSpent(), handler.ghostSpent());
        assertEq(
            address(hook).balance + hook.claimsOutstanding(),
            hook.treasuryAccrued() + hook.buybackAccrued() + handler.ghostNativeDonations()
        );
        assertEq(
            manager.balanceOf(address(hook), 0), hook.claimsOutstanding() + handler.ghostClaimDonations()
        );
        uint256 received;
        for (uint256 i; i < 4; ++i) {
            received += handler.recipients(i).balance;
        }
        assertEq(received, handler.ghostPaid(), "payouts reached only configured treasuries");
    }

    function invariant_everyTokenIsHeldOrActuallyBurned() public view {
        uint256 held = token.balanceOf(address(this)) + token.balanceOf(address(manager))
            + token.balanceOf(address(router)) + token.balanceOf(address(hook));
        for (uint256 i; i < 3; ++i) {
            held += token.balanceOf(handler.actors(i));
        }
        assertEq(held, token.totalSupply());
        assertEq(token.totalSupply() + handler.ghostBuybackBurns() + handler.ghostHolderBurns(), 1e27);
        assertEq(hook.totalTokensBurned(), handler.ghostBuybackBurns());
        assertEq(token.balanceOf(address(hook)), handler.ghostTokenDonations());
    }

    function invariant_rolesLaunchClockAndFeeBoundsPersist() public view {
        assertEq(hook.owner(), handler.expectedOwner());
        assertEq(hook.pendingOwner(), handler.expectedPendingOwner());
        assertEq(hook.treasury(), handler.expectedTreasury());
        assertTrue(hook.initialized());
        assertEq(hook.launchBlock(), handler.openedAt());
        uint256 age = block.number - handler.openedAt();
        assertEq(hook.launchFeePips(), age < 20 ? (20 - age) * 10_000 : 0);
        assertGe(hook.dynamicFeePips(), 3000);
        assertLe(hook.dynamicFeePips(), 20_000);
        assertEq(hook.dynamicFeePips(), handler.expectedDynamicFee(), "fee must match actual price history");
        assertEq(hook.quoteFeePips(), hook.launchFeePips() + hook.dynamicFeePips());
        (, int24 tick,, uint24 lpFee) = manager.getSlot0(hook.poolId());
        assertEq(hook.lastTick(), tick);
        assertEq(lpFee, 12_500);
    }

    function test_handlerReachesAllStatefulPaths() public {
        handler.redeem(1000, 2);
        handler.trade(0, 1e15, true, true);
        handler.trade(1, 1e15, false, false);
        handler.trade(2, 1e15, true, false);
        handler.trade(0, 1e15, false, true);
        for (uint8 i; i < 3; ++i) {
            handler.donate(1e12, i, i);
        }
        handler.holderBurn(1, 0);
        handler.nominate(1, false);
        handler.accept(0);
        handler.accept(1);
        handler.redirect(3);
        handler.claim(2);
        handler.buyback(10_000, true);
        for (uint8 i; i < 4; ++i) {
            handler.rejectedAction(i, 2);
        }
        handler.advance(20);
        assertEq(handler.successfulSwaps(), 4);
        assertEq(handler.successfulRedemptions(), 1);
        assertEq(handler.successfulClaims(), 1);
        assertEq(handler.successfulBuybacks(), 1);
        assertEq(handler.rejectedCalls(), 5);
        invariant_receiptsBackBothAllocationsDespiteDonations();
        invariant_everyTokenIsHeldOrActuallyBurned();
        invariant_rolesLaunchClockAndFeeBoundsPersist();
    }

    function test_priceHistoryOracleSurvivesRingReuse() public {
        for (uint8 i; i < 12; ++i) {
            handler.advance(i % 3 == 0 ? 16 : 3);
            handler.trade(i, 0.1 ether, true, true);
            handler.trade(i + 1, 0.1 ether, false, true);
            handler.buyback(1000, false);
            invariant_rolesLaunchClockAndFeeBoundsPersist();
        }
        handler.advance(8);
        assertEq(hook.dynamicFeePips(), 3000);
        invariant_rolesLaunchClockAndFeeBoundsPersist();
    }
}
