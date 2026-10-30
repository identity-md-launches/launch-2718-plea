// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PleaHook} from "src/PleaHook.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {FactoryStub} from "test/mocks/FactoryStub.sol";
import {Swapper} from "test/mocks/Swapper.sol";
import {PleaBase} from "test/PleaBase.t.sol";

/// @dev Real deployments in both address orderings, without etching production bytecode or storage.
abstract contract OrderedHookFixture is PleaBase {
    function wantsToken0() internal pure virtual returns (bool);

    function setUp() public virtual override {
        launch(true);
    }

    function pairCreationCode() internal pure virtual returns (bytes memory) {
        return abi.encodePacked(type(MockERC20).creationCode, abi.encode("IMD", "IMD", uint256(1e30)));
    }

    function deployPair(bytes32 salt) internal virtual returns (MockERC20) {
        return new MockERC20{salt: salt}("IMD", "IMD", 1e30);
    }

    function launch(bool seedLiquidity) internal {
        vm.warp(10 days);
        manager = new PoolManager(address(this));
        factory = new FactoryStub(manager);
        token = factory.deployToken();
        bytes memory pairCode = pairCreationCode();
        bytes32 hash = keccak256(pairCode);
        for (uint256 i; i < 100_000; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if ((address(token) < predicted) != wantsToken0() || predicted.code.length != 0) continue;
            imd = deployPair(bytes32(i));
            break;
        }
        require(address(imd) != address(0), "pair mining failed");
        bytes memory code =
            abi.encodePacked(type(PleaHook).creationCode, abi.encode(manager, address(token), owner, address(factory)));
        hook = PleaHook(factory.deploy(code, mineSalt(address(factory), code, FLAGS)));
        court = hook.court();
        letterbox = court.letterbox();
        key = PoolKey(
            Currency.wrap(wantsToken0() ? address(token) : address(imd)),
            Currency.wrap(wantsToken0() ? address(imd) : address(token)),
            POOL_FEE,
            TICK_SPACING,
            IHooks(address(hook))
        );
        factory.initialize(key, SQRT_PRICE_1_1);
        assertEq(hook.tokenIsCurrency0(), wantsToken0());
        imd.transfer(address(factory), 1e24);
        if (seedLiquidity) {
            factory.modify(key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 1e21);
        }
        swapper = new Swapper(manager);
        imd.transfer(address(swapper), 1e24);
        factory.send(IERC20(address(token)), address(swapper), 1e24);
        factory.send(IERC20(address(token)), seller, 1e24);
        imd.transfer(buyer, 1e24);
        imd.transfer(stranger, 1e24);
        delete judges;
        for (uint256 i; i < 30; ++i) {
            judges.push(makeAddr(string.concat("ordered judge", vm.toString(i))));
        }
        vm.prank(owner);
        court.setJudges(judges);
    }
}
