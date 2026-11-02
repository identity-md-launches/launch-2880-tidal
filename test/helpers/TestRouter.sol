// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Test-only router: balances left on it are liquidity funding, not user swap budgets.
contract TestRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    bool private entered;
    error Unauthorized();
    error BudgetExceeded();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 maxTokens)
        external
        payable
        returns (BalanceDelta delta)
    {
        require(!entered, "reentrant");
        entered = true;
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        if (maxTokens > 0) require(token.transferFrom(msg.sender, address(this), maxTokens));
        delta = abi.decode(
            manager.unlock(abi.encode(uint8(0), key, params, msg.value, maxTokens)), (BalanceDelta)
        );
        uint256 usedEth = delta.amount0() < 0 ? uint256(-int256(delta.amount0())) : 0;
        uint256 usedTokens = delta.amount1() < 0 ? uint256(-int256(delta.amount1())) : 0;
        uint256 tokensToSend = maxTokens - usedTokens;
        if (delta.amount1() > 0) tokensToSend += uint256(uint128(delta.amount1()));
        if (tokensToSend > 0) require(token.transfer(msg.sender, tokensToSend));
        uint256 ethToSend = msg.value - usedEth;
        if (delta.amount0() > 0) ethToSend += uint256(uint128(delta.amount0()));
        if (ethToSend > 0) {
            (bool ok,) = msg.sender.call{value: ethToSend}("");
            require(ok);
        }
        entered = false;
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity)
        external
        returns (BalanceDelta delta)
    {
        require(!entered, "reentrant");
        entered = true;
        delta = abi.decode(
            manager.unlock(abi.encode(uint8(1), key, ModifyLiquidityParams(lower, upper, liquidity, 0))),
            (BalanceDelta)
        );
        entered = false;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || !entered) revert Unauthorized();
        uint8 action = abi.decode(data, (uint8));
        PoolKey memory key;
        BalanceDelta delta;
        if (action == 0) {
            SwapParams memory params;
            uint256 maxEth;
            uint256 maxTokens;
            (, key, params, maxEth, maxTokens) =
                abi.decode(data, (uint8, PoolKey, SwapParams, uint256, uint256));
            delta = manager.swap(key, params, "");
            if (delta.amount0() < 0 && uint256(-int256(delta.amount0())) > maxEth) revert BudgetExceeded();
            if (delta.amount1() < 0 && uint256(-int256(delta.amount1())) > maxTokens) {
                revert BudgetExceeded();
            }
        } else {
            ModifyLiquidityParams memory params;
            (, key, params) = abi.decode(data, (uint8, PoolKey, ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        // Settle inputs before taking outputs, including on a manager with no prior ETH.
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        _take(key.currency0, delta.amount0());
        _take(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta >= 0) return;
        uint256 amount = uint256(-int256(delta));
        manager.sync(currency);
        if (Currency.unwrap(currency) == address(0)) {
            require(manager.settle{value: amount}() == amount);
        } else {
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount));
            require(manager.settle() == amount);
        }
    }

    function _take(Currency currency, int128 delta) private {
        if (delta > 0) manager.take(currency, address(this), uint256(uint128(delta)));
    }

    receive() external payable {}
}
