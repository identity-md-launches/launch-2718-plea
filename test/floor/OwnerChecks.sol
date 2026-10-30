// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Shared owner assertions for launch contracts: nothing deployed by the factory may be owned
/// by the factory or by the wallet that sent the launch transaction.
abstract contract OwnerChecks is Test {
    /// @dev Stands in for IMD's launch wallet as `tx.origin` while the contracts are deployed.
    address internal constant ORIGIN_PROBE = address(0x0000000000000000000000000000000000000719);

    /// @dev `target` either exposes no `owner()` or its owner is neither `factory` nor the origin probe.
    function checkOwner(string memory name, address target, address factory) internal view {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || data.length < 32) return;
        address owner = abi.decode(data, (address));
        assertTrue(owner != factory, string.concat(name, " is owned by the launch factory"));
        assertTrue(owner != ORIGIN_PROBE, string.concat(name, " is owned by the launch wallet (tx.origin)"));
        assertTrue(owner != address(0), string.concat(name, " has no owner"));
    }
}
