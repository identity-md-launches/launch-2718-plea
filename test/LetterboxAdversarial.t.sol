// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Letterbox} from "src/Letterbox.sol";
import {PleaCourt} from "src/PleaCourt.sol";
import {IPleaCourt} from "src/interfaces/IPleaCourt.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CourtFixture} from "test/helpers/CourtFixture.sol";

contract LetterboxAdversarialTest is CourtFixture {
    address internal signer;
    uint256 internal signingKey;

    function setUp() public override {
        super.setUp();
        (signer, signingKey) = makeAddrAndKey("letterbox test signer");
    }

    function signature(string memory text, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 hash =
            keccak256(abi.encode(box.PLEA_TYPEHASH(), signer, keccak256(bytes(text)), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", box.domainSeparator(), hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_signatureAtDeadlineAcceptedAndExpiredAttemptCannotBurnNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = signature("signed", 1, 0, deadline);
        vm.warp(deadline);
        vm.prank(bob);
        uint256 id = box.postSigned(signer, "signed", 1, deadline, sig);
        assertEq(court.plea(id).seller, signer);
        assertEq(box.nonces(signer), 1);
        vm.warp(deadline + 1);
        vm.expectRevert(Letterbox.Expired.selector);
        box.postSigned(signer, "signed", 1, deadline, sig);
        assertEq(box.nonces(signer), 1);
        assertEq(court.pleaCount(), 1);
    }

    function test_downstreamRevertPreservesSignatureForRetry() public {
        uint256 active = submit(signer, 1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = signature("retry", 2, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(PleaCourt.ActivePleaExists.selector, active));
        box.postSigned(signer, "retry", 2, deadline, sig);
        assertEq(box.nonces(signer), 0);
        assertEq(court.pleaCount(), 1);
        vm.prank(signer);
        court.withdrawPlea(active);
        uint256 id = box.postSigned(signer, "retry", 2, deadline, sig);
        assertEq(court.plea(id).amount, 2);
        assertEq(box.nonces(signer), 1);
        vm.prank(signer);
        court.withdrawPlea(id);
        vm.expectRevert(Letterbox.BadSignature.selector);
        box.postSigned(signer, "retry", 2, deadline, sig);
        assertEq(court.activePlea(signer), 0);
    }

    function test_directPostCannotSpendASignedNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = signature("signed", 2, 0, deadline);
        vm.prank(signer);
        uint256 directId = box.post("direct", 1);
        assertEq(box.nonces(signer), 0);
        vm.prank(signer);
        court.withdrawPlea(directId);
        uint256 signedId = box.postSigned(signer, "signed", 2, deadline, sig);
        assertEq(signedId, 2);
        assertEq(box.nonces(signer), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_modifyingAnySignedFieldFails(uint8 fieldSeed, uint128 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, uint256(type(uint128).max) - 1);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = signature("signed", amount, 0, deadline);
        uint256 field = fieldSeed % 4;
        address claimed = field == 0 ? bob : signer;
        string memory text = field == 1 ? "signeD" : "signed";
        uint256 postedAmount = field == 2 ? amount + 1 : amount;
        uint256 postedDeadline = field == 3 ? deadline + 1 : deadline;
        vm.expectRevert(Letterbox.BadSignature.selector);
        box.postSigned(claimed, text, postedAmount, postedDeadline, sig);
        assertEq(box.nonces(signer), 0);
        assertEq(box.nonces(bob), 0);
        assertEq(court.pleaCount(), 0);
        // The genuine signature is still usable after the forgery attempt.
        uint256 id = box.postSigned(signer, "signed", amount, deadline, sig);
        assertEq(court.plea(id).amount, amount);
        assertEq(court.plea(id).seller, signer);
    }

    function test_domainSeparatesLetterboxesAndChains() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = signature("domain", 1, 0, deadline);
        Letterbox other = new Letterbox(address(court));
        vm.expectRevert(Letterbox.BadSignature.selector);
        other.postSigned(signer, "domain", 1, deadline, sig);
        assertEq(other.nonces(signer), 0);
        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        vm.expectRevert(Letterbox.BadSignature.selector);
        box.postSigned(signer, "domain", 1, deadline, sig);
        assertEq(box.nonces(signer), 0);
        vm.chainId(chain);
        box.postSigned(signer, "domain", 1, deadline, sig);
        assertEq(box.nonces(signer), 1);
    }

    function test_malformedAndMalleableSignaturesCannotConsumeNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256[3] memory lengths = [uint256(0), 64, 66];
        for (uint256 i; i < lengths.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, lengths[i]));
            box.postSigned(signer, "x", 1, deadline, new bytes(lengths[i]));
        }
        bytes memory sig = signature("x", 1, 0, deadline);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        uint256 order = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes32 highS = bytes32(order - uint256(s));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        box.postSigned(signer, "x", 1, deadline, abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)));
        assertEq(box.nonces(signer), 0);
        assertEq(court.pendingCount(), 0);
        box.postSigned(signer, "x", 1, deadline, sig);
        assertEq(court.pendingCount(), 1);
    }
}
