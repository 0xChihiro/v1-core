///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Token} from "../src/Token.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";

contract TokenHalmosTest is Test, SymTest {
    address internal constant CONTROLLER = address(0xC0117011e2);
    address internal constant HOLDER = address(0xA11CE);
    address internal constant UNAUTHORIZED = address(0xB0B);
    uint256 internal constant SYMBOLIC_MAX_SUPPLY = type(uint128).max;
    uint256 internal constant SYMBOLIC_PREMINE = type(uint64).max;

    function check_tokenMintNeverExceedsMaxSupply() public {
        uint256 mintAmount = svm.createUint(128, "token mint amount");

        _assertMintNeverExceedsMaxSupply(SYMBOLIC_MAX_SUPPLY, SYMBOLIC_PREMINE, mintAmount);
    }

    function check_tokenOnlyControllerCanChangeSupply() public {
        uint256 amount = svm.createUint(64, "token access amount");

        _assertOnlyControllerCanChangeSupply(SYMBOLIC_MAX_SUPPLY, SYMBOLIC_PREMINE, amount, UNAUTHORIZED);
    }

    function check_tokenControllerBurnReducesSupplyAndHolderBalance() public {
        uint256 burnAmount = svm.createUint(64, "token burn amount");

        _assertControllerBurnReducesSupplyAndHolderBalance(SYMBOLIC_MAX_SUPPLY, SYMBOLIC_PREMINE, burnAmount);
    }

    function testConcreteTokenMintNeverExceedsMaxSupply() public {
        _assertMintNeverExceedsMaxSupply(1_000, 100, 900);
        _assertMintNeverExceedsMaxSupply(1_000, 100, 901);
    }

    function testConcreteTokenOnlyControllerCanChangeSupply() public {
        _assertOnlyControllerCanChangeSupply(1_000, 100, 50, address(0xB0B));
    }

    function testConcreteTokenControllerBurnReducesSupplyAndHolderBalance() public {
        _assertControllerBurnReducesSupplyAndHolderBalance(1_000, 100, 50);
    }

    function _assertMintNeverExceedsMaxSupply(uint256 maxSupply, uint256 preMineAmount, uint256 mintAmount) internal {
        Token token = new Token("Enten", "ENTEN", CONTROLLER, HOLDER, preMineAmount, maxSupply);
        uint256 beforeSupply = token.totalSupply();
        uint256 beforeBalance = token.balanceOf(HOLDER);

        if (mintAmount <= maxSupply - beforeSupply) {
            vm.prank(CONTROLLER);
            token.mint(HOLDER, mintAmount);

            assertEq(token.totalSupply(), beforeSupply + mintAmount);
            assertEq(token.balanceOf(HOLDER), beforeBalance + mintAmount);
        } else {
            vm.prank(CONTROLLER);
            (bool success, bytes memory returnData) =
                address(token).call(abi.encodeCall(Token.mint, (HOLDER, mintAmount)));

            assertFalse(success);
            assertEq(_revertSelector(returnData), Token.Token__MaxSupply.selector);
            assertEq(token.totalSupply(), beforeSupply);
            assertEq(token.balanceOf(HOLDER), beforeBalance);
        }

        assertLe(token.totalSupply(), token.MAX_SUPPLY());
    }

    function _assertOnlyControllerCanChangeSupply(
        uint256 maxSupply,
        uint256 preMineAmount,
        uint256 amount,
        address caller
    ) internal {
        Token token = new Token("Enten", "ENTEN", CONTROLLER, HOLDER, preMineAmount, maxSupply);
        uint256 beforeSupply = token.totalSupply();
        uint256 beforeHolderBalance = token.balanceOf(HOLDER);
        uint256 beforeCallerBalance = token.balanceOf(caller);

        vm.prank(caller);
        (bool mintSuccess, bytes memory mintReturnData) =
            address(token).call(abi.encodeCall(Token.mint, (caller, amount)));
        assertFalse(mintSuccess);
        assertEq(_revertSelector(mintReturnData), Token.Token__OnlyController.selector);

        vm.prank(caller);
        (bool burnSuccess, bytes memory burnReturnData) =
            address(token).call(abi.encodeCall(Token.burnFrom, (HOLDER, amount)));
        assertFalse(burnSuccess);
        assertEq(_revertSelector(burnReturnData), Token.Token__OnlyController.selector);

        assertEq(token.totalSupply(), beforeSupply);
        assertEq(token.balanceOf(HOLDER), beforeHolderBalance);
        assertEq(token.balanceOf(caller), beforeCallerBalance);
    }

    function _assertControllerBurnReducesSupplyAndHolderBalance(
        uint256 maxSupply,
        uint256 preMineAmount,
        uint256 burnAmount
    ) internal {
        Token token = new Token("Enten", "ENTEN", CONTROLLER, HOLDER, preMineAmount, maxSupply);
        uint256 beforeSupply = token.totalSupply();
        uint256 beforeBalance = token.balanceOf(HOLDER);

        vm.prank(CONTROLLER);
        token.burnFrom(HOLDER, burnAmount);

        assertEq(token.totalSupply(), beforeSupply - burnAmount);
        assertEq(token.balanceOf(HOLDER), beforeBalance - burnAmount);
        assertLe(token.totalSupply(), token.MAX_SUPPLY());
    }

    function _revertSelector(bytes memory returnData) internal pure returns (bytes4 selector) {
        assert(returnData.length >= 4);
        assembly ("memory-safe") {
            selector := mload(add(returnData, 0x20))
        }
    }
}
