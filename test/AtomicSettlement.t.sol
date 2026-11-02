// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {AtomicProbe} from "./helpers/AtomicProbe.sol";
import {TidalHook} from "src/TidalHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract AtomicSettlementTest is Fixture {
    function _probe() internal returns (AtomicProbe probe) {
        probe = new AtomicProbe(hook);
        vm.deal(address(probe), 1000 ether);
        token.transfer(address(probe), 1000 ether);
    }

    function test_twoUnsettledBuysMintClaimsOnFreshManager() public {
        _fresh();
        AtomicProbe probe = _probe();
        SwapParams[] memory params = new SwapParams[](2);
        params[0] = SwapParams(true, -50 ether, TickMath.MIN_SQRT_PRICE + 1);
        params[1] = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        (BalanceDelta[] memory deltas, uint24[] memory rates) = probe.batch(params, "");
        assertEq(rates[0], 203_000);
        assertEq(rates[1], 220_000, "second call must use first call's movement");
        assertEq(deltas[0].amount0(), -50 ether);
        assertEq(deltas[1].amount0(), -1 ether);
        assertEq(hook.totalFeesCollected(), 10.37 ether);
        assertEq(hook.claimsOutstanding(), 10.37 ether, "both fees precede router settlement");
        assertEq(address(hook).balance, 0);
        assertEq(address(manager).balance, 51 ether);
        assertEq(probe.checkedSwaps(), 2);
        assertEq(probe.checkedSettlements(), 1);
        hook.claimTreasury();
        _assertAccounting();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fourModesNetSettleInsideOneUnlock(uint96 raw, uint8 age) public {
        vm.roll(hook.launchBlock() + bound(age, 0, 30));
        AtomicProbe probe = _probe();
        uint256 amount = bound(raw, 1e9, 1 ether);
        SwapParams[] memory params = new SwapParams[](4);
        params[0] = SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1);
        params[1] = SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1);
        params[2] = SwapParams(true, int256(amount), TickMath.MIN_SQRT_PRICE + 1);
        params[3] = SwapParams(false, int256(amount), TickMath.MAX_SQRT_PRICE - 1);
        uint256 beforeETH = address(probe).balance;
        uint256 beforeTokens = token.balanceOf(address(probe));
        uint256 managerETH = address(manager).balance;
        (BalanceDelta[] memory deltas,) = probe.batch(params, abi.encode(creator, true));
        int256 ethNet;
        int256 tokenNet;
        for (uint256 i; i < 4; ++i) {
            ethNet += deltas[i].amount0();
            tokenNet += deltas[i].amount1();
        }
        assertEq(int256(address(probe).balance) - int256(beforeETH), ethNet);
        assertEq(int256(token.balanceOf(address(probe))) - int256(beforeTokens), tokenNet);
        assertEq(deltas[0].amount0(), -int256(amount));
        assertEq(deltas[1].amount1(), -int256(amount));
        assertEq(deltas[2].amount1(), int256(amount));
        assertEq(deltas[3].amount0(), int256(amount));
        assertEq(
            int256(address(manager).balance) - int256(managerETH),
            -ethNet - int256(hook.totalFeesCollected()),
            "ETH conserved across pool, probe, and hook"
        );
        assertEq(probe.checkedSwaps(), 4);
        assertEq(probe.checkedSettlements(), 1);
        _assertAccounting();
    }

    function test_buybackClearsPreexistingTokenSyncBeforePayingETH() public {
        _swap(true, -5 ether);
        AtomicProbe probe = _probe();
        vm.prank(creator);
        hook.transferOwnership(address(probe));
        probe.acceptOwnership();
        uint256 budget = hook.buybackAccrued();
        uint256 supplyBefore = token.totalSupply();
        uint256 probeTokens = token.balanceOf(address(probe));
        (uint256 spent, uint256 burned) = probe.syncTokenThenBuyback(budget);
        assertEq(spent, budget);
        assertGt(burned, 0);
        assertEq(token.totalSupply(), supplyBefore - burned);
        assertEq(token.balanceOf(address(probe)), probeTokens, "operator receives no buyback tokens");
        _assertAccounting();
    }

    function test_nestedUnlockFailuresLeaveAuthorizationRetryable() public {
        _fresh();
        _swap(true, -5 ether);
        AtomicProbe probe = _probe();
        vm.prank(creator);
        hook.transferOwnership(address(probe));
        probe.acceptOwnership();
        uint256 claims = hook.claimsOutstanding();
        uint256 budget = hook.buybackAccrued();
        uint256 treasury = hook.treasuryAccrued();
        probe.attemptNestedUnlocks();
        assertEq(hook.claimsOutstanding(), claims);
        assertEq(hook.buybackAccrued(), budget);
        assertEq(hook.treasuryAccrued(), treasury);
        assertEq(hook.totalTreasuryPaid(), 0);
        assertEq(hook.totalBuybackSpent(), 0);
        // None of the failed unlock attempts may leave an action authorized or the guard entered.
        vm.prank(address(manager));
        vm.expectRevert(TidalHook.InvalidUnlock.selector);
        hook.unlockCallback(abi.encode(1));
        hook.redeemClaims(1);
        hook.claimTreasury();
        probe.syncTokenThenBuyback(budget);
        _assertAccounting();
    }
}
