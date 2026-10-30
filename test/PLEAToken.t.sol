// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEAToken} from "../src/PLEAToken.sol";

contract PLEATokenTest is Test {
    PLEAToken token;

    function setUp() public {
        token = new PLEAToken();
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "PLEA");
        assertEq(token.symbol(), "PLEA");
    }

    function test_transferMovesExactly() public {
        address to = makeAddr("to");
        assertTrue(token.transfer(to, 5 ether));
        assertEq(token.balanceOf(to), 5 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 5 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferMoreThanBalanceReverts() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_noMintFunction() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }
}
