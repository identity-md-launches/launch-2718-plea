// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PLEA
/// @notice The launch token: a fixed-supply, standard ERC-20. 1,000,000,000 PLEA (18 decimals) minted
/// once to the deployer (the launch factory). No owner, mint, pause, blocklist, fee or upgrade path.
/// Every rule of the launch (sell gating, the Cabal, seasons) lives in the hook, never here.
contract PLEAToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("PLEA", "PLEA") {
        _mint(msg.sender, SUPPLY);
    }
}
