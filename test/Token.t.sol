///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Token} from "../src/Token.sol";
import {IToken} from "../src/interfaces/IToken.sol";
import {Test} from "forge-std/Test.sol";

contract TokenTest is Test {
    uint256 internal constant MAX_SUPPLY = 1_000_000 ether;
    uint256 internal constant PRE_MINE_AMOUNT = 100_000 ether;

    address internal controller = makeAddr("Controller");
    address internal preMineReceiver = makeAddr("Pre Mine Receiver");
    address internal user = makeAddr("User");
    address internal stranger = makeAddr("Stranger");

    function testConstructorSetsLaunchParametersWithoutPreMine() public {
        Token token = new Token("Enten", "ENTEN", controller, address(0), 0, MAX_SUPPLY);
        IToken tokenView = IToken(address(token));

        assertEq(tokenView.name(), "Enten");
        assertEq(tokenView.symbol(), "ENTEN");
        assertEq(tokenView.decimals(), 18);
        assertEq(tokenView.CONTROLLER(), controller);
        assertEq(tokenView.MAX_SUPPLY(), MAX_SUPPLY);
        assertEq(tokenView.totalSupply(), 0);
        assertEq(tokenView.balanceOf(preMineReceiver), 0);
    }

    function testConstructorMintsPreMineAndUsesItAsInitialSupply() public {
        Token token = new Token("Enten", "ENTEN", controller, preMineReceiver, PRE_MINE_AMOUNT, MAX_SUPPLY);

        assertEq(token.totalSupply(), PRE_MINE_AMOUNT);
        assertEq(token.balanceOf(preMineReceiver), PRE_MINE_AMOUNT);
        assertEq(token.MAX_SUPPLY(), MAX_SUPPLY);
    }

    function testConstructorAllowsPreMineEqualToMaxSupply() public {
        Token token = new Token("Enten", "ENTEN", controller, preMineReceiver, MAX_SUPPLY, MAX_SUPPLY);

        assertEq(token.totalSupply(), MAX_SUPPLY);
        assertEq(token.balanceOf(preMineReceiver), MAX_SUPPLY);
    }

    function testConstructorRejectsZeroController() public {
        vm.expectRevert(Token.Token__InvalidController.selector);
        new Token("Enten", "ENTEN", address(0), address(0), 0, MAX_SUPPLY);
    }

    function testConstructorRejectsZeroMaxSupply() public {
        vm.expectRevert(Token.Token__MaxSupply.selector);
        new Token("Enten", "ENTEN", controller, address(0), 0, 0);
    }

    function testConstructorRejectsPreMineWithZeroReceiver() public {
        vm.expectRevert(Token.Token__PreMineMisconfigured.selector);
        new Token("Enten", "ENTEN", controller, address(0), PRE_MINE_AMOUNT, MAX_SUPPLY);
    }

    function testConstructorRejectsPreMineAboveMaxSupply() public {
        vm.expectRevert(Token.Token__PreMineMisconfigured.selector);
        new Token("Enten", "ENTEN", controller, preMineReceiver, MAX_SUPPLY + 1, MAX_SUPPLY);
    }

    function testOnlyControllerCanMint() public {
        Token token = new Token("Enten", "ENTEN", controller, address(0), 0, MAX_SUPPLY);

        vm.prank(stranger);
        vm.expectRevert(Token.Token__OnlyController.selector);
        token.mint(user, 1 ether);

        vm.prank(controller);
        token.mint(user, 1 ether);

        assertEq(token.totalSupply(), 1 ether);
        assertEq(token.balanceOf(user), 1 ether);
    }

    function testMintEnforcesMaxSupplyIncludingPreMine() public {
        Token token = new Token("Enten", "ENTEN", controller, preMineReceiver, PRE_MINE_AMOUNT, MAX_SUPPLY);

        vm.prank(controller);
        token.mint(user, MAX_SUPPLY - PRE_MINE_AMOUNT);

        assertEq(token.totalSupply(), MAX_SUPPLY);
        assertEq(token.balanceOf(user), MAX_SUPPLY - PRE_MINE_AMOUNT);

        vm.prank(controller);
        vm.expectRevert(Token.Token__MaxSupply.selector);
        token.mint(user, 1);

        assertEq(token.totalSupply(), MAX_SUPPLY);
    }

    function testOnlyControllerCanBurn() public {
        Token token = new Token("Enten", "ENTEN", controller, preMineReceiver, PRE_MINE_AMOUNT, MAX_SUPPLY);

        vm.prank(stranger);
        vm.expectRevert(Token.Token__OnlyController.selector);
        token.burnFrom(preMineReceiver, 1 ether);

        assertEq(token.totalSupply(), PRE_MINE_AMOUNT);
        assertEq(token.balanceOf(preMineReceiver), PRE_MINE_AMOUNT);
    }

    function testControllerCanBurnWithoutAllowance() public {
        Token token = new Token("Enten", "ENTEN", controller, preMineReceiver, PRE_MINE_AMOUNT, MAX_SUPPLY);

        assertEq(token.allowance(preMineReceiver, controller), 0);

        vm.prank(controller);
        token.burnFrom(preMineReceiver, 1 ether);

        assertEq(token.totalSupply(), PRE_MINE_AMOUNT - 1 ether);
        assertEq(token.balanceOf(preMineReceiver), PRE_MINE_AMOUNT - 1 ether);
        assertEq(token.allowance(preMineReceiver, controller), 0);
    }

    function testBurningRestoresMintCapacity() public {
        Token token = new Token("Enten", "ENTEN", controller, preMineReceiver, MAX_SUPPLY, MAX_SUPPLY);

        vm.prank(controller);
        token.burnFrom(preMineReceiver, 1 ether);

        assertEq(token.totalSupply(), MAX_SUPPLY - 1 ether);

        vm.prank(controller);
        token.mint(user, 1 ether);

        assertEq(token.totalSupply(), MAX_SUPPLY);
        assertEq(token.balanceOf(user), 1 ether);
    }
}
