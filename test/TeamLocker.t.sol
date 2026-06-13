///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Kernel} from "../src/Kernel.sol";
import {TeamLocker} from "../src/TeamLocker.sol";
import {Slots} from "../src/libraries/Slots.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract TeamLockerTest is Test {
    uint256 internal constant STARTING_LOCKED = 100 ether;

    Kernel kernel;
    TeamLocker locker;
    ERC20Mock token;

    address controller = makeAddr("Controller");
    address vault = makeAddr("Vault");
    address admin = makeAddr("Admin");
    address receiver = makeAddr("Receiver");
    address stranger = makeAddr("Stranger");

    function setUp() public {
        kernel = new Kernel(controller, vault);
        token = new ERC20Mock();
        locker = new TeamLocker(STARTING_LOCKED, admin, address(token), address(kernel));
        token.mint(address(locker), STARTING_LOCKED);
    }

    function testConstructorSetsRolesAndImmutables() public view {
        assertEq(locker.STARTING_LOCKED(), STARTING_LOCKED);
        assertEq(locker.TOKEN(), address(token));
        assertEq(address(locker.KERNEL()), address(kernel));
        assertTrue(locker.hasRole(locker.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(locker.hasRole(locker.CLAIMER_ROLE(), admin));
    }

    function testConstructorRejectsInvalidInputs() public {
        vm.expectRevert(TeamLocker.TeamLocker__ZeroLockedTokens.selector);
        new TeamLocker(0, admin, address(token), address(kernel));

        vm.expectRevert(TeamLocker.TeamLocker__ZeroAddress.selector);
        new TeamLocker(STARTING_LOCKED, address(0), address(token), address(kernel));

        vm.expectRevert(TeamLocker.TeamLocker__ZeroAddress.selector);
        new TeamLocker(STARTING_LOCKED, admin, address(0), address(kernel));

        vm.expectRevert(TeamLocker.TeamLocker__ZeroAddress.selector);
        new TeamLocker(STARTING_LOCKED, admin, address(token), address(0));
    }

    function testClaimTransfersOnlyUnlockedTokens() public {
        _setStillLocked(70 ether);

        vm.prank(admin);
        locker.claim(30 ether, receiver);

        assertEq(locker.claimed(), 30 ether);
        assertEq(token.balanceOf(receiver), 30 ether);
        assertEq(token.balanceOf(address(locker)), 70 ether);

        vm.prank(admin);
        vm.expectRevert(TeamLocker.TeamLocker__NotEnoughTokensUnlocked.selector);
        locker.claim(1, receiver);
    }

    function testClaimAllTransfersRemainingUnlockedTokens() public {
        _setStillLocked(60 ether);

        vm.prank(admin);
        locker.claim(25 ether, receiver);

        _setStillLocked(40 ether);

        vm.prank(admin);
        locker.claimAll(receiver);

        assertEq(locker.claimed(), 60 ether);
        assertEq(token.balanceOf(receiver), 60 ether);
        assertEq(token.balanceOf(address(locker)), 40 ether);
    }

    function testClaimAllRevertsWhenNothingIsUnlocked() public {
        _setStillLocked(STARTING_LOCKED);

        vm.prank(admin);
        vm.expectRevert(TeamLocker.TeamLocked__NoTokensToClaim.selector);
        locker.claimAll(receiver);
    }

    function testOnlyClaimerCanClaim() public {
        _setStillLocked(70 ether);

        vm.prank(stranger);
        vm.expectRevert();
        locker.claim(1 ether, receiver);

        vm.prank(stranger);
        vm.expectRevert();
        locker.claimAll(receiver);
    }

    function _setStillLocked(uint256 amount) internal {
        vm.prank(controller);
        kernel.updateState(Slots.TEAM_LOCKED_TOKENS_SLOT, bytes32(amount));
    }
}
