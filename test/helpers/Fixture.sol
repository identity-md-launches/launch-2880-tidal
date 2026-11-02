// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TidalHook} from "../../src/TidalHook.sol";
import {TidalToken} from "../../src/TidalToken.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TestRouter} from "./TestRouter.sol";

abstract contract Fixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant Q96 = 79228162514264337593543950336;
    uint160 internal constant FLAGS = 0x10cc;
    uint256 internal constant D = 1_000_000;
    IPoolManager internal manager;
    TidalToken internal token;
    TidalHook internal hook;
    TestRouter internal router;
    PoolKey internal key;
    address internal creator;
    address internal stranger;

    function setUp() public virtual {
        creator = makeAddr("pool creator");
        stranger = makeAddr("stranger");
        _deploy();
        _seed(false);
    }

    function _deploy() internal {
        vm.roll(100);
        vm.warp(1_700_000_000);
        vm.deal(address(this), 100_000 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new TidalToken();
        hook = _deployHook(manager, token, creator, address(this));
        router = new TestRouter(manager);
        key = hook.getPoolKey();
        token.approve(address(router), 1_000_000 ether);
        token.transfer(address(router), 10_000 ether);
        vm.deal(address(router), 10_000 ether);
    }

    function _seed(bool tokensOnly) internal {
        manager.initialize(key, Q96);
        router.modify(key, -60000, tokensOnly ? int24(0) : int24(60000), 1000 ether);
    }

    function _fresh() internal {
        _deploy();
        _seed(true);
        assertEq(address(manager).balance, 0);
        assertGt(token.balanceOf(address(manager)), 0);
    }

    function _deployHook(IPoolManager pm, TidalToken tid, address own, address fac)
        internal
        returns (TidalHook result)
    {
        bytes memory code = abi.encodePacked(type(TidalHook).creationCode, abi.encode(pm, tid, own, fac));
        bytes32 codeHash = keccak256(code);
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash))))
            );
            if (uint160(predicted) & 0x3fff != FLAGS) continue;
            address deployed;
            assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
            require(deployed == predicted, "CREATE2 hook failed");
            return TidalHook(payable(deployed));
        }
        revert("salt search exhausted");
    }

    function _calm() internal {
        vm.roll(block.number + 21);
    }

    function _swap(bool buy, int256 amount) internal returns (BalanceDelta) {
        return router.swap{value: buy ? 100 ether : 0}(
            key,
            SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            buy ? 0 : 100 ether
        );
    }

    function _assertAccounting() internal view {
        uint256 fees = hook.totalFeesCollected();
        assertEq(hook.treasuryAccrued() + hook.totalTreasuryPaid(), fees / 2, "treasury partition");
        assertEq(hook.buybackAccrued() + hook.totalBuybackSpent(), fees - fees / 2, "buyback partition");
        assertEq(
            address(hook).balance + hook.claimsOutstanding(),
            hook.treasuryAccrued() + hook.buybackAccrued(),
            "assets back liabilities"
        );
        assertEq(manager.balanceOf(address(hook), 0), hook.claimsOutstanding(), "claims backed by manager");
        assertEq(token.INITIAL_SUPPLY() - token.totalSupply(), hook.totalTokensBurned(), "real token burn");
        assertEq(token.balanceOf(address(hook)), 0, "no unburned buyback tokens");
        assertEq(manager.getNonzeroDeltaCount(), 0, "all manager deltas settled");
        assertFalse(manager.isUnlocked(), "manager relocked");
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
    }

    function _gross(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return (amount * rate + D - rate - 1) / (D - rate);
    }

    receive() external payable {}
}
