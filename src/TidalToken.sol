// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Tidal has a fixed initial supply, ordinary transfers, and holder-only destruction.
/// @dev The launch factory receives all tokens. There are no mint or administrative entry points.
contract TidalToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Tidal", "TIDAL") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Permanently destroy the caller's own tokens, decreasing totalSupply.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
