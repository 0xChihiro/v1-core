///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Controller} from "../src/Controller.sol";
import {Kernel} from "../src/Kernel.sol";
import {ProtocolCollector} from "../src/ProtocolCollector.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {Slots} from "../src/libraries/Slots.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract ProtocolCollectorTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    ProtocolCollector collector;
    Controller controller;
    Kernel kernel;
    Vault vault;
    Token token;
    ERC20Mock asset;

    address admin = makeAddr("Admin");
    address user = makeAddr("User");

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedCollector = vm.computeCreateAddress(address(this), nonce);
        address predictedKernel = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 3);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 4);

        collector = new ProtocolCollector(admin);
        assertEq(address(collector), predictedCollector);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, user, INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(admin, predictedCollector, predictedKernel, predictedVault, predictedToken);
        asset = new ERC20Mock();
    }

    function testSetControllerAndVaultValidatesWiringAndCreditorRole() public {
        vm.prank(admin);
        vm.expectRevert(ProtocolCollector.ProtocolCollector__MisconfiguredSetup.selector);
        collector.setControllerAndVault(address(controller), address(vault));

        bytes32 creditorRole = controller.CREDITOR_ROLE();
        vm.prank(admin);
        controller.grantRole(creditorRole, address(collector));

        vm.prank(admin);
        collector.setControllerAndVault(address(controller), address(vault));

        assertEq(address(collector.controller()), address(controller));
        assertEq(collector.vault(), address(vault));

        vm.prank(admin);
        vm.expectRevert(ProtocolCollector.ProtocolCollector__AddressesSet.selector);
        collector.setControllerAndVault(address(controller), address(vault));
    }

    function testSetControllerAndVaultRejectsWrongCollector() public {
        ProtocolCollector wrongCollector = new ProtocolCollector(admin);

        bytes32 creditorRole = controller.CREDITOR_ROLE();
        vm.prank(admin);
        controller.grantRole(creditorRole, address(wrongCollector));

        vm.prank(admin);
        vm.expectRevert(ProtocolCollector.ProtocolCollector__MisconfiguredSetup.selector);
        wrongCollector.setControllerAndVault(address(controller), address(vault));
    }

    function testAddBackingTransfersAndCreditsRedeem() public {
        _grantAndSet();
        asset.mint(address(collector), 100 ether);

        vm.prank(admin);
        collector.add(_singleAdd(address(asset), 60 ether));

        assertEq(asset.balanceOf(address(collector)), 40 ether);
        assertEq(asset.balanceOf(address(vault)), 60 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 60 ether);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 0);
    }

    function testAddTreasuryTransfersAndCreditsTreasury() public {
        _grantAndSet();
        asset.mint(address(collector), 100 ether);

        vm.prank(admin);
        collector.addTreasury(_singleAdd(address(asset), 70 ether));

        assertEq(asset.balanceOf(address(collector)), 30 ether);
        assertEq(asset.balanceOf(address(vault)), 70 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 70 ether);
    }

    function testAddPathsRequireSeparateRoles() public {
        _grantAndSet();
        address backingOperator = makeAddr("Backing Operator");
        address treasuryOperator = makeAddr("Treasury Operator");
        asset.mint(address(collector), 100 ether);

        vm.startPrank(admin);
        collector.grantRole(collector.ADD_BACKING_ROLE(), backingOperator);
        collector.grantRole(collector.ADD_TREASURY_ROLE(), treasuryOperator);
        vm.stopPrank();

        vm.prank(backingOperator);
        collector.add(_singleAdd(address(asset), 10 ether));

        vm.prank(backingOperator);
        vm.expectRevert();
        collector.addTreasury(_singleAdd(address(asset), 10 ether));

        vm.prank(treasuryOperator);
        collector.addTreasury(_singleAdd(address(asset), 10 ether));

        vm.prank(treasuryOperator);
        vm.expectRevert();
        collector.add(_singleAdd(address(asset), 10 ether));
    }

    function testAddPathsRequireConfiguredAddresses() public {
        asset.mint(address(collector), 100 ether);

        vm.prank(admin);
        vm.expectRevert(ProtocolCollector.ProtocolCollector__AddressesNotSet.selector);
        collector.add(_singleAdd(address(asset), 10 ether));

        vm.prank(admin);
        vm.expectRevert(ProtocolCollector.ProtocolCollector__AddressesNotSet.selector);
        collector.addTreasury(_singleAdd(address(asset), 10 ether));
    }

    function _grantAndSet() internal {
        bytes32 creditorRole = controller.CREDITOR_ROLE();
        vm.prank(admin);
        controller.grantRole(creditorRole, address(collector));

        vm.prank(admin);
        collector.setControllerAndVault(address(controller), address(vault));
    }

    function _singleAdd(address addAsset, uint256 amount) internal pure returns (ProtocolCollector.Adds[] memory adds) {
        adds = new ProtocolCollector.Adds[](1);
        adds[0] = ProtocolCollector.Adds({asset: addAsset, amount: amount});
    }

    function _bucketValue(IVault.Bucket bucket, address token_) internal view returns (uint256) {
        if (bucket == IVault.Bucket.Redeem) return uint256(kernel.viewData(_slot(Slots.BACKING_AMOUNT_SLOT, token_)));
        if (bucket == IVault.Bucket.Treasury) {
            return uint256(kernel.viewData(_slot(Slots.TREASURY_AMOUNT_SLOT, token_)));
        }
        revert("unsupported bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(token_, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }
}
