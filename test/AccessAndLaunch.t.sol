// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {TidalHook} from "../src/TidalHook.sol";
import {TidalToken} from "../src/TidalToken.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract AccessAndLaunchTest is Fixture {
    function test_constructorUsesExplicitOwnerAndNoExternalCalls() public {
        assertEq(hook.owner(), creator);
        assertEq(hook.treasury(), creator);
        assertTrue(hook.owner() != address(this));
        TidalHook isolated = _deployHook(
            IPoolManager(makeAddr("empty manager")),
            TidalToken(makeAddr("empty token")),
            creator,
            address(this)
        );
        assertEq(isolated.owner(), creator);
        assertFalse(isolated.initialized());
    }

    function test_hookPermissionsExactlyMatchAddressAndCallbacks() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertLe(address(hook).code.length, 24_576);
    }

    function test_allImplementedCallbacksRejectNonManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(TidalHook.OnlyPoolManager.selector);
        hook.afterInitialize(address(this), key, Q96, 0);
        vm.expectRevert(TidalHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(TidalHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(TidalHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(TidalHook.InvalidUnlock.selector);
        hook.unlockCallback("");
    }

    function test_onlyFactoryCanInitializeOnce() public {
        _deploy();
        assertFalse(hook.initialized());
        vm.prank(stranger);
        vm.expectRevert();
        manager.initialize(key, Q96);
        assertFalse(hook.initialized());
        assertEq(hook.launchBlock(), 0);
        manager.initialize(key, Q96);
        assertTrue(hook.initialized());
        assertEq(hook.launchBlock(), block.number);
        vm.expectRevert();
        manager.initialize(key, Q96);
        vm.prank(address(manager));
        vm.expectRevert(TidalHook.AlreadyInitialized.selector);
        hook.afterInitialize(address(this), key, Q96, 0);
    }

    function test_uninitializedHookIsClearlyUnavailable() public {
        _deploy();
        vm.expectRevert(TidalHook.NotInitialized.selector);
        hook.quoteFeePips();
        vm.prank(creator);
        vm.expectRevert(TidalHook.NotInitialized.selector);
        hook.executeBuyback(1, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
    }

    function test_initializationRejectsWrongTokenFeeSpacingAndHook() public {
        _deploy();
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong = hook.getPoolKey();
        wrong.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong = hook.getPoolKey();
        wrong.currency1 = key.currency0;
        vm.prank(address(manager));
        vm.expectRevert(TidalHook.WrongPool.selector);
        hook.afterInitialize(address(this), wrong, Q96, 0);
        wrong = hook.getPoolKey();
        wrong.hooks = IHooks(stranger);
        vm.prank(address(manager));
        vm.expectRevert(TidalHook.WrongPool.selector);
        hook.afterInitialize(address(this), wrong, Q96, 0);
        assertFalse(hook.initialized());
        manager.initialize(hook.getPoolKey(), Q96);
    }

    function test_swapCannotUseAnotherPoolOrHookDataExemption() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.prank(address(manager));
        vm.expectRevert(TidalHook.WrongPool.selector);
        hook.beforeSwap(stranger, wrong, params, "");
        vm.prank(address(manager));
        vm.expectRevert(TidalHook.WrongPool.selector);
        hook.afterSwap(stranger, wrong, params, BalanceDelta.wrap(0), "");
        // Even a forged owner/router identity in hookData does not change the returned fee.
        vm.prank(address(manager));
        (, int256 delta,) = _callBefore(params, abi.encode(creator, true));
        assertEq(delta >> 128, 0.203 ether);
    }

    function _callBefore(SwapParams memory params, bytes memory data)
        internal
        returns (bytes4, int256, uint24)
    {
        (bool ok, bytes memory result) =
            address(hook).call(abi.encodeCall(IHooks.beforeSwap, (creator, key, params, data)));
        require(ok);
        return abi.decode(result, (bytes4, int256, uint24));
    }

    function test_swapAmountBounds() public {
        int256[4] memory amounts =
            [int256(0), type(int256).min, type(int256).max, int256(type(int128).max) + 1];
        for (uint256 i; i < amounts.length; ++i) {
            vm.prank(address(manager));
            vm.expectRevert(TidalHook.InvalidAmount.selector);
            hook.beforeSwap(stranger, key, SwapParams(true, amounts[i], TickMath.MIN_SQRT_PRICE + 1), "");
        }
    }

    function test_ownerControlsTreasuryAndTwoStepOwnership() public {
        vm.prank(stranger);
        vm.expectRevert();
        hook.setTreasury(stranger);
        vm.startPrank(creator);
        vm.expectRevert(TidalHook.InvalidTreasury.selector);
        hook.setTreasury(address(0));
        vm.expectRevert(TidalHook.InvalidTreasury.selector);
        hook.setTreasury(address(hook));
        vm.expectRevert(TidalHook.InvalidTreasury.selector);
        hook.setTreasury(address(manager));
        vm.expectRevert(TidalHook.InvalidTreasury.selector);
        hook.setTreasury(address(token));
        vm.expectRevert(TidalHook.RenounceDisabled.selector);
        hook.renounceOwnership();
        hook.transferOwnership(stranger);
        vm.stopPrank();
        assertEq(hook.owner(), creator);
        vm.expectRevert();
        hook.acceptOwnership();
        vm.prank(stranger);
        hook.acceptOwnership();
        assertEq(hook.owner(), stranger);
        assertEq(hook.treasury(), creator, "ownership transfer does not silently redirect fees");
        vm.prank(stranger);
        hook.setTreasury(stranger);
        assertEq(hook.treasury(), stranger);
        vm.prank(creator);
        vm.expectRevert();
        hook.setTreasury(creator);
    }

    function test_invalidConstructorInputsAndUnminedAddressRefused() public {
        vm.expectRevert(TidalHook.ZeroAddress.selector);
        new TidalHook(IPoolManager(address(0)), token, creator, address(this));
        vm.expectRevert(TidalHook.ZeroAddress.selector);
        new TidalHook(manager, TidalToken(address(0)), creator, address(this));
        vm.expectRevert(TidalHook.ZeroAddress.selector);
        new TidalHook(manager, token, creator, address(0));
        vm.expectRevert();
        new TidalHook(manager, token, address(0), address(this));
        vm.expectRevert();
        new TidalHook(manager, token, creator, address(this));
    }

    function test_runtimeHasNoEscapeHatches() public view {
        _scan(address(hook).code);
        _scan(address(token).code);
    }

    function _scan(bytes memory code) internal pure {
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            if (reachable) require(op != 0xff && op != 0xf4 && op != 0xf2, "escape hatch opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }
}
