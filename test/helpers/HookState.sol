// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TidalHook} from "src/TidalHook.sol";
import {TidalToken} from "src/TidalToken.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Public economic state used to check that a rejected call is atomic.
library HookState {
    using StateLibrary for IPoolManager;

    function digest(TidalHook hook) internal view returns (bytes32) {
        IPoolManager manager = hook.poolManager();
        TidalToken token = hook.token();
        uint256[12] memory ledger = [
            hook.treasuryAccrued(),
            hook.buybackAccrued(),
            hook.claimsOutstanding(),
            hook.totalFeesCollected(),
            hook.totalTreasuryPaid(),
            hook.totalBuybackSpent(),
            hook.totalTokensBurned(),
            address(hook).balance,
            address(manager).balance,
            manager.balanceOf(address(hook), 0),
            token.totalSupply(),
            token.balanceOf(address(hook))
        ];
        bytes32 observations;
        for (uint256 i; i < 8; ++i) {
            (uint64 at, uint64 movement) = hook.observations(i);
            observations = keccak256(abi.encode(observations, at, movement));
        }
        bytes32 roles = keccak256(
            abi.encode(
                hook.owner(),
                hook.pendingOwner(),
                hook.treasury(),
                hook.initialized(),
                hook.launchBlock(),
                hook.lastTick()
            )
        );
        return keccak256(abi.encode(ledger, observations, _poolDigest(hook), roles));
    }

    function _poolDigest(TidalHook hook) private view returns (bytes32) {
        IPoolManager manager = hook.poolManager();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(hook.poolId());
        bytes32 slot0 = keccak256(abi.encode(price, tick, protocolFee, lpFee));
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(hook.poolId());
        return keccak256(
            abi.encode(
                slot0,
                growth0,
                growth1,
                manager.getLiquidity(hook.poolId()),
                hook.token().balanceOf(address(manager))
            )
        );
    }
}
