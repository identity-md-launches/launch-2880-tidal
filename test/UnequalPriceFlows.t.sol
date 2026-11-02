// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev A second price regime: approximately 50 million TIDAL per ETH, not the 1:1 unit fixture.
/// The price is a test scenario, not an asserted deployment parameter or an oracle quote.
contract UnequalPriceFlowsTest is Fixture {
    function _open(bool tokensOnly) private {
        _deploy();
        token.approve(address(router), 2_000_000 ether);
        token.transfer(address(router), 800_000_000 ether);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(177300));
        router.modify(key, 120000, tokensOnly ? int24(177300) : int24(240000), 100_000 ether);
        if (tokensOnly) assertEq(address(manager).balance, 0);
        else assertGt(address(manager).balance, 0);
    }

    function test_allSwapModesAndBuybackAtUnequalPriceWithCashFees() public {
        _open(false);
        _exercise();
    }

    function test_allSwapModesAndBuybackAtUnequalPriceWithFreshClaims() public {
        _open(true);
        _exercise();
    }

    function _exercise() private {
        uint256 startETH = address(this).balance;
        uint256 startTokens = token.balanceOf(address(this));
        BalanceDelta buyInput =
            router.swap{value: 1 ether}(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), 0);
        assertEq(buyInput.amount0(), -1 ether);
        assertGt(buyInput.amount1(), 1_000_000 ether, "fixture exercises unequal token units");
        assertEq(startETH - address(this).balance, 1 ether);
        assertEq(token.balanceOf(address(this)) - startTokens, uint256(uint128(buyInput.amount1())));
        assertEq(hook.totalFeesCollected(), 0.203 ether);
        _assertAccounting();

        // Subsequent modes have deliberately different ETH and TIDAL magnitudes.
        BalanceDelta buyOutput =
            router.swap{value: 1 ether}(key, SwapParams(true, 1000 ether, TickMath.MIN_SQRT_PRICE + 1), 0);
        assertEq(buyOutput.amount1(), 1000 ether);
        assertLt(uint256(-int256(buyOutput.amount0())), 0.001 ether);
        BalanceDelta sellInput =
            router.swap(key, SwapParams(false, -1000 ether, TickMath.MAX_SQRT_PRICE - 1), 1000 ether);
        assertEq(sellInput.amount1(), -1000 ether);
        assertGt(sellInput.amount0(), 0);
        BalanceDelta sellOutput =
            router.swap(key, SwapParams(false, 0.001 ether, TickMath.MAX_SQRT_PRICE - 1), 1_000_000 ether);
        assertEq(sellOutput.amount0(), 0.001 ether);
        assertLt(sellOutput.amount1(), 0);
        _assertAccounting();

        uint256 budget = hook.buybackAccrued();
        uint256 owed = hook.treasuryAccrued();
        uint256 supplyBefore = token.totalSupply();
        uint256 ownerTokens = token.balanceOf(creator);
        vm.prank(creator);
        (uint256 spent, uint256 burned) =
            hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        assertEq(spent, budget);
        assertGt(burned, 0);
        assertEq(supplyBefore - token.totalSupply(), burned);
        assertEq(token.balanceOf(creator), ownerTokens);
        hook.claimTreasury();
        assertEq(creator.balance, owed);
        assertEq(hook.buybackAccrued(), 0);
        assertEq(hook.treasuryAccrued(), 0);
        _assertAccounting();
    }
}
