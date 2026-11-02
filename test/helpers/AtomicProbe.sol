// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TidalHook} from "src/TidalHook.sol";
import {TidalToken} from "src/TidalToken.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Runs dependent operations inside ONE top-level call, before transient storage is cleared.
/// Test-funded balances belong to this probe. It never pulls tokens from another payer.
contract AtomicProbe is Test, IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    TidalHook public immutable hook;
    TidalToken public immutable token;
    address private immutable controller;
    PoolKey private key;
    uint256 public checkedSwaps;
    uint256 public checkedSettlements;

    constructor(TidalHook hook_) {
        hook = hook_;
        manager = hook_.poolManager();
        token = hook_.token();
        key = hook_.getPoolKey();
        controller = msg.sender;
    }

    modifier onlyController() {
        require(msg.sender == controller, "controller");
        _;
    }

    function batch(SwapParams[] memory params, bytes memory hookData)
        external
        onlyController
        returns (BalanceDelta[] memory deltas, uint24[] memory rates)
    {
        bytes memory result = manager.unlock(abi.encode(uint8(0), params, hookData));
        assertFalse(manager.isUnlocked(), "manager must relock before the transaction ends");
        assertEq(manager.getNonzeroDeltaCount(), 0);
        return abi.decode(result, (BalanceDelta[], uint24[]));
    }

    function acceptOwnership() external onlyController {
        hook.acceptOwnership();
    }

    function syncTokenThenBuyback(uint256 budget) external onlyController returns (uint256, uint256) {
        manager.sync(key.currency1);
        assertEq(Currency.unwrap(manager.getSyncedCurrency()), address(token));
        (uint256 spent, uint256 burned) =
            hook.executeBuyback(budget, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        return (spent, burned);
    }

    function attemptNestedUnlocks() external onlyController {
        manager.unlock(abi.encode(uint8(1)));
        assertFalse(manager.isUnlocked());
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        assertTrue(manager.isUnlocked(), "must inspect live transient state");
        uint8 action = abi.decode(data, (uint8));
        if (action == 1) {
            _refusesNested(abi.encodeCall(TidalHook.redeemClaims, (1)));
            _refusesNested(abi.encodeCall(TidalHook.claimTreasury, ()));
            _refusesNested(
                abi.encodeCall(
                    TidalHook.executeBuyback,
                    (hook.buybackAccrued(), 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp)
                )
            );
            assertEq(manager.getNonzeroDeltaCount(), 0);
            return "";
        }
        (, SwapParams[] memory params, bytes memory hookData) = abi.decode(data, (uint8, SwapParams[], bytes));
        BalanceDelta[] memory deltas = new BalanceDelta[](params.length);
        uint24[] memory rates = new uint24[](params.length);
        int256 nativeNet;
        int256 tokenNet;
        for (uint256 i; i < params.length; ++i) {
            rates[i] = hook.quoteFeePips();
            deltas[i] = manager.swap(key, params[i], hookData);
            nativeNet += deltas[i].amount0();
            tokenNet += deltas[i].amount1();
            assertEq(manager.currencyDelta(address(this), key.currency0), nativeNet);
            assertEq(manager.currencyDelta(address(this), key.currency1), tokenNet);
            assertEq(manager.currencyDelta(address(hook), key.currency0), 0, "hook ETH delta unsettled");
            assertEq(manager.currencyDelta(address(hook), key.currency1), 0, "hook token delta unsettled");
            assertGt(manager.getNonzeroDeltaCount(), 0, "probe must have live swap deltas");
            ++checkedSwaps;
        }
        _pay(key.currency0, nativeNet);
        _pay(key.currency1, tokenNet);
        _take(key.currency0, nativeNet);
        _take(key.currency1, tokenNet);
        assertEq(manager.getNonzeroDeltaCount(), 0, "settled inside the callback");
        assertTrue(manager.isUnlocked(), "callback still executing");
        ++checkedSettlements;
        return abi.encode(deltas, rates);
    }

    function _refusesNested(bytes memory data) private {
        (bool ok, bytes memory reason) = address(hook).call(data);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
    }

    function _pay(Currency currency, int256 amount) private {
        if (amount >= 0) return;
        manager.sync(currency);
        if (currency.isAddressZero()) {
            assertEq(manager.settle{value: uint256(-amount)}(), uint256(-amount));
        } else {
            assertTrue(token.transfer(address(manager), uint256(-amount)));
            assertEq(manager.settle(), uint256(-amount));
        }
    }

    function _take(Currency currency, int256 amount) private {
        if (amount > 0) manager.take(currency, address(this), uint256(amount));
    }

    receive() external payable {}
}
