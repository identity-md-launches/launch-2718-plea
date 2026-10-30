// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Letterbox} from "../src/Letterbox.sol";
import {PleaCourt} from "../src/PleaCourt.sol";
import {IPleaCourt} from "../src/interfaces/IPleaCourt.sol";
import {PleaBase} from "./PleaBase.t.sol";

contract LetterboxTest is PleaBase {
    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    function setUp() public override {
        super.setUp();
        signer = vm.addr(signerKey);
    }

    function _sign(address who, string memory text, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(letterbox.PLEA_TYPEHASH(), who, keccak256(bytes(text)), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", letterbox.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_postDirect() public {
        vm.prank(seller);
        vm.expectEmit(true, true, true, true);
        emit Letterbox.Posted(1, seller, seller);
        uint256 id = letterbox.post("via letterbox", 3);
        IPleaCourt.Plea memory p = court.plea(id);
        assertEq(p.seller, seller);
        assertEq(p.amount, 3);
        assertEq(court.activePlea(seller), id);
    }

    function test_postSignedByRelayer() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(signer, "signed plea", 7, 0, deadline);
        vm.prank(stranger);
        vm.expectEmit(true, true, true, true);
        emit Letterbox.Posted(1, signer, stranger);
        uint256 id = letterbox.postSigned(signer, "signed plea", 7, deadline, sig);
        assertEq(court.plea(id).seller, signer);
        assertEq(letterbox.nonces(signer), 1);
        // replay is refused by the nonce
        vm.prank(stranger);
        vm.expectRevert(Letterbox.BadSignature.selector);
        letterbox.postSigned(signer, "signed plea", 7, deadline, sig);
    }

    function test_postSignedRejectsForgeryAndExpiry() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(signer, "signed plea", 7, 0, deadline);
        vm.expectRevert(Letterbox.BadSignature.selector);
        letterbox.postSigned(seller, "signed plea", 7, deadline, sig); // another seller
        vm.expectRevert(Letterbox.BadSignature.selector);
        letterbox.postSigned(signer, "signed plea", 8, deadline, sig); // another amount
        vm.warp(deadline + 1);
        vm.expectRevert(Letterbox.Expired.selector);
        letterbox.postSigned(signer, "signed plea", 7, deadline, sig);
    }

    function test_onlyLetterboxMaySubmitFor() public {
        vm.prank(stranger);
        vm.expectRevert(PleaCourt.NotHook.selector);
        court.submitPleaFor(seller, "x", 1);
    }
}
