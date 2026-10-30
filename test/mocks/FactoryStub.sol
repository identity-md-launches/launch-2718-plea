// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PLEAToken} from "../../src/PLEAToken.sol";

/// @notice Stands in for the launch factory: deploys the token and the hook, opens the pool, holds the
/// seeded position and collects its fees with a zero liquidity change.
contract FactoryStub is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deployToken() external returns (PLEAToken token) {
        token = new PLEAToken();
    }

    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "deploy failed");
    }

    function initialize(PoolKey memory key, uint160 price) external {
        manager.initialize(key, price);
    }

    function send(IERC20 token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }

    function modify(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity)
        external
        returns (int128, int128)
    {
        return abi.decode(manager.unlock(abi.encode(key, tickLower, tickUpper, liquidity)), (int128, int128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: 0}),
            ""
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta.amount0(), delta.amount1());
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
