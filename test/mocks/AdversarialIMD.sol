// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @dev Deliberately hostile dependency for failure/reentrancy tests; not a claim about mainnet IMD.
contract AdversarialIMD is MockERC20 {
    error TransferRefused();
    address public rejectedRecipient;
    bool public reject;
    bool public returnFalse;
    address public watchedRecipient;
    address public callbackTarget;
    bytes public callbackData;
    bool internal inside;
    uint256 public attempts;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() MockERC20("IMD", "IMD", 1e30) {}

    function setRejection(address recipient, bool enabled) external {
        rejectedRecipient = recipient;
        reject = enabled;
    }

    function setReturnFalse(bool enabled) external {
        returnFalse = enabled;
    }

    function setCallback(address recipient, address target, bytes calldata data) external {
        watchedRecipient = recipient;
        callbackTarget = target;
        callbackData = data;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        return result;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        return super.transferFrom(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (reject && to == rejectedRecipient) revert TransferRefused();
        super._update(from, to, value);
        if (callbackTarget != address(0) && to == watchedRecipient && !inside) {
            inside = true;
            attempts++;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
            inside = false;
        }
    }
}
