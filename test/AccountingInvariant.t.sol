// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {TidalToken} from "../src/TidalToken.sol";
import {TidalHook} from "../src/TidalHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract AccountingHandler is Test {
    TidalHook public hook;
    TidalToken public token;
    TestRouter public router;
    IPoolManager public manager;
    PoolKey private key;
    address private creator;
    uint256 public ghostFees;
    uint256 public swapCount;
    uint256 public operationCount;
    uint256 private constant D = 1_000_000;

    constructor(
        TidalHook hook_,
        TidalToken token_,
        TestRouter router_,
        IPoolManager manager_,
        address creator_
    ) {
        hook = hook_;
        token = token_;
        router = router_;
        manager = manager_;
        creator = creator_;
        key = hook.getPoolKey();
        token.approve(address(router), 10_000 ether);
        ghostFees = hook.totalFeesCollected();
    }

    function swap(uint96 raw, bool buy, bool exactInput) external {
        uint256 amount = bound(raw, 1e10, 1 ether);
        uint256 beforeFees = hook.totalFeesCollected();
        uint256 beforeManager = address(manager).balance;
        uint256 rate = hook.quoteFeePips();
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        BalanceDelta delta = router.swap{value: buy ? 10 ether : 0}(
            key,
            SwapParams(buy, specified, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            buy ? 0 : 10 ether
        );
        uint256 expectedFee;
        if (buy && exactInput) {
            expectedFee = amount * rate / D;
            assertEq(delta.amount0(), -int256(amount));
        } else if (!buy && !exactInput) {
            expectedFee = (amount * rate + D - rate - 1) / (D - rate);
            assertEq(delta.amount0(), int256(amount));
        } else if (buy) {
            // Invert the gross-up from actual gross ETH paid, without reading the hook's fee accounting.
            uint256 grossPaid = uint256(-int256(delta.amount0()));
            expectedFee = (grossPaid * rate + D - 1) / D;
            assertEq(delta.amount1(), int256(amount));
        } else {
            // These funded-manager sequences take fees in ETH: the actual manager outflow is gross output.
            uint256 grossOutput = beforeManager - address(manager).balance;
            expectedFee = grossOutput * rate / D;
            assertEq(delta.amount1(), -int256(amount));
        }
        assertEq(hook.totalFeesCollected() - beforeFees, expectedFee);
        ghostFees += expectedFee;
        ++swapCount;
        ++operationCount;
    }

    function advance(uint8 blocks_) external {
        vm.roll(block.number + bound(blocks_, 0, 30));
        ++operationCount;
    }

    function claim() external {
        if (hook.treasuryAccrued() > 0) hook.claimTreasury();
        ++operationCount;
    }

    function redeem(uint256 raw) external {
        uint256 claims = hook.claimsOutstanding();
        if (claims > 0) hook.redeemClaims(bound(raw, 1, claims));
        ++operationCount;
    }

    function buyback(uint16 fraction) external {
        uint256 pending = hook.buybackAccrued();
        if (pending < 1000) return;
        uint256 amount = pending * bound(fraction, 1, 10_000) / 10_000;
        if (amount < 1000) amount = pending;
        vm.prank(creator);
        hook.executeBuyback(amount, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp + 60);
        ++operationCount;
    }

    receive() external payable {}
}

contract AccountingInvariantTest is Fixture {
    AccountingHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        _startHandler();
    }

    function _startHandler() internal {
        handler = new AccountingHandler(hook, token, router, manager, creator);
        token.transfer(address(handler), 10_000 ether);
        vm.deal(address(handler), 10_000 ether);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = AccountingHandler.swap.selector;
        selectors[1] = AccountingHandler.advance.selector;
        selectors[2] = AccountingHandler.claim.selector;
        selectors[3] = AccountingHandler.redeem.selector;
        selectors[4] = AccountingHandler.buyback.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_assetsSplitsBurnsAndDeltasConserve() public view {
        _assertAccounting();
        assertEq(hook.totalFeesCollected(), handler.ghostFees());
        assertGe(hook.dynamicFeePips(), 3000);
        assertLe(hook.dynamicFeePips(), 20_000);
        assertLe(hook.quoteFeePips(), 220_000);
        assertEq(hook.owner(), creator);
        assertEq(hook.treasury(), creator);
    }
}

contract ClaimsAccountingInvariantTest is AccountingInvariantTest {
    function setUp() public override {
        creator = makeAddr("pool creator");
        stranger = makeAddr("stranger");
        _fresh();
        // Enough native reserve for even 32 consecutive maximum-size exact-output sells.
        _swap(true, -80 ether);
        assertGt(hook.claimsOutstanding(), 0);
        _startHandler();
    }
}
