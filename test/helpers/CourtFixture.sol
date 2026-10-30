// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PleaCourt} from "src/PleaCourt.sol";
import {IPleaCourt} from "src/interfaces/IPleaCourt.sol";
import {Letterbox} from "src/Letterbox.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @dev Court-only fixture. Hook/PoolManager integration is exercised separately.
contract CourtHookDriver {
    address public owner;
    PleaCourt public immutable court;

    constructor(address owner_, address imd) {
        owner = owner_;
        court = new PleaCourt(address(this));
        court.bind(imd);
    }

    function authorize(address seller, uint256 amount) external returns (uint256) {
        return court.authorizeSale(seller, amount);
    }

    function transferOwner(address next) external {
        require(msg.sender == owner, "owner only");
        owner = next;
    }
}

abstract contract CourtFixture is Test {
    CourtHookDriver internal driver;
    PleaCourt internal court;
    Letterbox internal box;
    MockERC20 internal imd;
    address internal owner;
    address internal alice;
    address internal bob;
    address internal outsider;
    address[] internal panel;

    function setUp() public virtual {
        vm.warp(10 days);
        owner = makeAddr("court owner");
        alice = makeAddr("court alice");
        bob = makeAddr("court bob");
        outsider = makeAddr("court outsider");
        imd = new MockERC20("Local IMD", "IMD", 1e30);
        driver = new CourtHookDriver(owner, address(imd));
        court = driver.court();
        box = court.letterbox();
        for (uint256 i; i < 30; ++i) {
            panel.push(makeAddr(string.concat("cabal ", vm.toString(i))));
        }
        vm.prank(owner);
        court.setJudges(panel);
        imd.transfer(alice, 1000 ether);
        imd.transfer(bob, 1000 ether);
        imd.transfer(outsider, 1000 ether);
    }

    function submit(address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        return court.submitPlea("Verifiable facts for this test", amount);
    }

    function vote(uint256 id, uint256 first, uint256 count, uint8 raw, uint8 facts) internal {
        for (uint256 i = first; i < first + count; ++i) {
            vm.prank(panel[i]);
            court.judge(id, raw, facts);
        }
    }

    function approved(address who, uint256 amount, uint8 raw) internal returns (uint256 id) {
        id = submit(who, amount);
        vote(id, 0, 17, raw, 71);
    }

    function objectTo(address who, uint256 sale) internal returns (uint256 oid) {
        vm.startPrank(who);
        imd.approve(address(court), 1 ether);
        oid = court.object(sale);
        vm.stopPrank();
    }

    function rule(uint256 oid, bool uphold) internal {
        for (uint256 i; i < 17; ++i) {
            vm.prank(panel[i]);
            court.ruleObjection(oid, uphold);
        }
    }
}
