// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IPleaIntake {
    function submitPleaFor(address seller, string calldata text, uint256 amount) external returns (uint256);
}

/// @title Letterbox
/// @notice A drop-box for pleas. A seller posts directly, or signs a plea (EIP-712) and anyone, such as a
/// relayer paying the gas, posts it for them. The court records the plea under the seller's address.
contract Letterbox is EIP712 {
    bytes32 public constant PLEA_TYPEHASH =
        keccak256("Plea(address seller,string text,uint256 amount,uint256 nonce,uint256 deadline)");

    error Expired();
    error BadSignature();

    event Posted(uint256 indexed pleaId, address indexed seller, address indexed poster);
    event NonceInvalidated(address indexed seller, uint256 nonce);

    IPleaIntake public immutable court;
    mapping(address => uint256) public nonces;

    constructor(address court_) EIP712("PLEA Letterbox", "1") {
        court = IPleaIntake(court_);
    }

    /// @notice Posts the caller's own plea.
    function post(string calldata text, uint256 amount) external returns (uint256 pleaId) {
        pleaId = court.submitPleaFor(msg.sender, text, amount);
        emit Posted(pleaId, msg.sender, msg.sender);
    }

    /// @notice Posts a plea `seller` signed. Uses the seller's next nonce; valid until `deadline`.
    function postSigned(
        address seller,
        string calldata text,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 pleaId) {
        if (block.timestamp > deadline) revert Expired();
        uint256 nonce = nonces[seller]++;
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(PLEA_TYPEHASH, seller, keccak256(bytes(text)), amount, nonce, deadline))
        );
        if (ECDSA.recover(digest, signature) != seller) revert BadSignature();
        pleaId = court.submitPleaFor(seller, text, amount);
        emit Posted(pleaId, seller, msg.sender);
    }

    /// @notice Cancels every plea the caller signed with their current nonce, by spending it.
    function invalidateNonce() external returns (uint256 nonce) {
        nonce = nonces[msg.sender]++;
        emit NonceInvalidated(msg.sender, nonce);
    }

    /// @notice The EIP-712 domain separator, for signers.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
