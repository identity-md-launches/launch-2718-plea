// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PLEAToken} from "../src/PLEAToken.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {PleaCourt} from "../src/PleaCourt.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FactoryStub} from "./mocks/FactoryStub.sol";
import {Swapper} from "./mocks/Swapper.sol";

/// @notice Shared launch fixture: a fresh PoolManager, the token deployed by a factory stub, the hook mined
/// onto its flags and deployed by that factory, the pool opened and seeded by it, and a configured Cabal.
abstract contract PleaBase is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant FLAGS =
        HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_ADD_LIQUIDITY | HookFlags.BEFORE_SWAP;

    address internal owner = makeAddr("owner");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    PoolManager internal manager;
    MockERC20 internal imd;
    FactoryStub internal factory;
    PLEAToken internal token;
    PleaHook internal hook;
    PleaCourt internal court;
    Letterbox internal letterbox;
    Swapper internal swapper;
    PoolKey internal key;
    address[] internal judges;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        imd = new MockERC20("IMD", "IMD", 1e30);
        factory = new FactoryStub(manager);
        token = factory.deployToken();
        assertEq(token.balanceOf(address(factory)), token.SUPPLY());

        bytes memory code =
            abi.encodePacked(type(PleaHook).creationCode, abi.encode(manager, address(token), owner, address(factory)));
        hook = PleaHook(factory.deploy(code, mineSalt(address(factory), code, FLAGS)));
        court = hook.court();
        letterbox = court.letterbox();

        (address c0, address c1) =
            address(token) < address(imd) ? (address(token), address(imd)) : (address(imd), address(token));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        factory.initialize(key, SQRT_PRICE_1_1);

        imd.transfer(address(factory), 1e24);
        factory.modify(key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 1e21);

        swapper = new Swapper(manager);
        imd.transfer(address(swapper), 1e24);
        factory.send(IERC20(address(token)), address(swapper), 1e24);
        factory.send(IERC20(address(token)), seller, 1e24);
        imd.transfer(buyer, 1e24);
        imd.transfer(stranger, 1e24);

        for (uint256 i = 0; i < 30; i++) {
            judges.push(makeAddr(string.concat("judge", vm.toString(i))));
        }
        vm.prank(owner);
        court.setJudges(judges);
    }

    function mineSalt(address deployer, bytes memory code, uint160 flags) internal pure returns (bytes32) {
        bytes32 initCodeHash = keccak256(code);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, flags)) return bytes32(i);
        }
        revert("no salt");
    }

    /// @dev `judges[0..n)` score `score` with `facts` fact points.
    function score(uint256 pleaId, uint256 n, uint8 score_, uint8 facts) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(judges[i]);
            court.judge(pleaId, score_, facts);
        }
    }

    function approvePlea(uint256 pleaId) internal {
        score(pleaId, 17, 45, 26);
    }

    function denyPlea(uint256 pleaId) internal {
        score(pleaId, 17, 10, 0);
    }

    function submitAndApprove(address who, uint256 amount) internal returns (uint256 pleaId) {
        vm.prank(who);
        pleaId = court.submitPlea("I have a plea. The facts: the sky is blue.", amount);
        approvePlea(pleaId);
    }

    function sellIsZeroForOne() internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(token);
    }

    function buy(uint256 imdIn) internal {
        swapper.swap(key, !sellIsZeroForOne(), imdIn);
    }
}
