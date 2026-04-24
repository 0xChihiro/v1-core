///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IController} from "../src/interfaces/IController.sol";
import {IKernel} from "../src/interfaces/IKernel.sol";
import {Kernel} from "../src/Kernel.sol";

contract ControllerMock is IController {
    mapping(address => bool) internal permissioned;
    mapping(address => bool) internal access;

    function setPermissioned(address caller, bool isAllowed) external {
        permissioned[caller] = isAllowed;
    }

    function isPermissioned(address caller) external view returns (bool) {
        return permissioned[caller];
    }

    function setAccess(address caller, bool isAllowed) external {
        access[caller] = isAllowed;
    }

    function vaultAccess(address caller) external view returns (bool) {
        return access[caller];
    }
}

contract KernelTest is Test {
    ControllerMock internal controller;
    Kernel internal kernel;
    address internal constant WRITER = address(0xBEEF);
    address internal constant STRANGER = address(0xCAFE);

    function setUp() public {
        controller = new ControllerMock();
        kernel = new Kernel(address(controller));
    }

    function testConstructorRevertsForZeroController() public {
        vm.expectRevert(Kernel.Kernel__ControllerZeroAddress.selector);
        new Kernel(address(0));
    }

    function testUpdateStateWritesSequentialSlots() public {
        bytes32 startSlot = bytes32(uint256(7));
        bytes memory data = abi.encode(bytes32(uint256(11)), bytes32(uint256(22)), bytes32(uint256(33)));

        controller.setPermissioned(WRITER, true);
        vm.prank(WRITER);
        kernel.updateState(startSlot, data);

        assertEq(vm.load(address(kernel), startSlot), bytes32(uint256(11)));
        assertEq(vm.load(address(kernel), _slotOffset(startSlot, 1)), bytes32(uint256(22)));
        assertEq(vm.load(address(kernel), _slotOffset(startSlot, 2)), bytes32(uint256(33)));
    }

    function testUpdateStateAllowsEmptyDataWithoutMutatingStorage() public {
        bytes32 startSlot = bytes32(uint256(13));

        vm.store(address(kernel), startSlot, bytes32(uint256(555)));
        vm.store(address(kernel), _slotOffset(startSlot, 1), bytes32(uint256(777)));

        controller.setPermissioned(WRITER, true);
        vm.prank(WRITER);
        kernel.updateState(startSlot, bytes(""));

        assertEq(vm.load(address(kernel), startSlot), bytes32(uint256(555)));
        assertEq(vm.load(address(kernel), _slotOffset(startSlot, 1)), bytes32(uint256(777)));
    }

    function testUpdateStateSingleSlotWritesData() public {
        bytes32 slot = bytes32(uint256(17));
        bytes32 value = bytes32(uint256(999));

        controller.setPermissioned(WRITER, true);
        vm.prank(WRITER);
        kernel.updateState(slot, value);

        assertEq(vm.load(address(kernel), slot), value);
    }

    function testUpdateStateBatchWritesData() public {
        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: bytes32(uint256(31)), data: bytes32(uint256(111))});
        calls[1] = IKernel.KernelCall({slot: bytes32(uint256(32)), data: bytes32(uint256(222))});
        calls[2] = IKernel.KernelCall({slot: bytes32(uint256(33)), data: bytes32(uint256(333))});

        controller.setPermissioned(WRITER, true);
        vm.prank(WRITER);
        kernel.updateState(calls);

        assertEq(vm.load(address(kernel), calls[0].slot), calls[0].data);
        assertEq(vm.load(address(kernel), calls[1].slot), calls[1].data);
        assertEq(vm.load(address(kernel), calls[2].slot), calls[2].data);
    }

    function testUpdateStateBatchAllowsEmptyArrayWithoutMutatingStorage() public {
        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](0);
        bytes32 slot = bytes32(uint256(34));

        vm.store(address(kernel), slot, bytes32(uint256(444)));

        controller.setPermissioned(WRITER, true);
        vm.prank(WRITER);
        kernel.updateState(calls);

        assertEq(vm.load(address(kernel), slot), bytes32(uint256(444)));
    }

    function testAddSingleSlotAddsValue() public {
        bytes32 slot = bytes32(uint256(51));

        vm.store(address(kernel), slot, bytes32(uint256(10)));
        controller.setPermissioned(WRITER, true);

        vm.prank(WRITER);
        kernel.add(slot, bytes32(uint256(7)));

        assertEq(vm.load(address(kernel), slot), bytes32(uint256(17)));
    }

    function testAddBatchAddsValues() public {
        bytes32 slotOne = bytes32(uint256(52));
        bytes32 slotTwo = bytes32(uint256(53));
        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);

        vm.store(address(kernel), slotOne, bytes32(uint256(10)));
        vm.store(address(kernel), slotTwo, bytes32(uint256(20)));

        calls[0] = IKernel.KernelCall({slot: slotOne, data: bytes32(uint256(7))});
        calls[1] = IKernel.KernelCall({slot: slotTwo, data: bytes32(uint256(9))});

        controller.setPermissioned(WRITER, true);
        vm.prank(WRITER);
        kernel.add(calls);

        assertEq(vm.load(address(kernel), slotOne), bytes32(uint256(17)));
        assertEq(vm.load(address(kernel), slotTwo), bytes32(uint256(29)));
    }

    function testAddSingleSlotRevertsOnOverflow() public {
        bytes32 slot = bytes32(uint256(54));

        vm.store(address(kernel), slot, bytes32(type(uint256).max));
        controller.setPermissioned(WRITER, true);

        vm.expectRevert(Kernel.Kernel__AddOverflow.selector);
        vm.prank(WRITER);
        kernel.add(slot, bytes32(uint256(1)));

        assertEq(vm.load(address(kernel), slot), bytes32(type(uint256).max));
    }

    function testAddBatchRevertsOnOverflow() public {
        bytes32 slotOne = bytes32(uint256(55));
        bytes32 slotTwo = bytes32(uint256(56));
        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);

        vm.store(address(kernel), slotOne, bytes32(uint256(10)));
        vm.store(address(kernel), slotTwo, bytes32(type(uint256).max));

        calls[0] = IKernel.KernelCall({slot: slotOne, data: bytes32(uint256(7))});
        calls[1] = IKernel.KernelCall({slot: slotTwo, data: bytes32(uint256(1))});

        controller.setPermissioned(WRITER, true);

        vm.expectRevert(Kernel.Kernel__AddOverflow.selector);
        vm.prank(WRITER);
        kernel.add(calls);

        assertEq(vm.load(address(kernel), slotOne), bytes32(uint256(10)));
        assertEq(vm.load(address(kernel), slotTwo), bytes32(type(uint256).max));
    }

    function testSubSingleSlotSubtractsValue() public {
        bytes32 slot = bytes32(uint256(57));

        vm.store(address(kernel), slot, bytes32(uint256(20)));
        controller.setPermissioned(WRITER, true);

        vm.prank(WRITER);
        kernel.sub(slot, bytes32(uint256(7)));

        assertEq(vm.load(address(kernel), slot), bytes32(uint256(13)));
    }

    function testSubBatchSubtractsValues() public {
        bytes32 slotOne = bytes32(uint256(58));
        bytes32 slotTwo = bytes32(uint256(59));
        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);

        vm.store(address(kernel), slotOne, bytes32(uint256(20)));
        vm.store(address(kernel), slotTwo, bytes32(uint256(30)));

        calls[0] = IKernel.KernelCall({slot: slotOne, data: bytes32(uint256(7))});
        calls[1] = IKernel.KernelCall({slot: slotTwo, data: bytes32(uint256(9))});

        controller.setPermissioned(WRITER, true);
        vm.prank(WRITER);
        kernel.sub(calls);

        assertEq(vm.load(address(kernel), slotOne), bytes32(uint256(13)));
        assertEq(vm.load(address(kernel), slotTwo), bytes32(uint256(21)));
    }

    function testSubSingleSlotRevertsOnUnderflow() public {
        bytes32 slot = bytes32(uint256(60));

        vm.store(address(kernel), slot, bytes32(uint256(5)));
        controller.setPermissioned(WRITER, true);

        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        vm.prank(WRITER);
        kernel.sub(slot, bytes32(uint256(6)));

        assertEq(vm.load(address(kernel), slot), bytes32(uint256(5)));
    }

    function testSubBatchRevertsOnUnderflow() public {
        bytes32 slotOne = bytes32(uint256(61));
        bytes32 slotTwo = bytes32(uint256(62));
        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);

        vm.store(address(kernel), slotOne, bytes32(uint256(20)));
        vm.store(address(kernel), slotTwo, bytes32(uint256(5)));

        calls[0] = IKernel.KernelCall({slot: slotOne, data: bytes32(uint256(7))});
        calls[1] = IKernel.KernelCall({slot: slotTwo, data: bytes32(uint256(6))});

        controller.setPermissioned(WRITER, true);

        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        vm.prank(WRITER);
        kernel.sub(calls);

        assertEq(vm.load(address(kernel), slotOne), bytes32(uint256(20)));
        assertEq(vm.load(address(kernel), slotTwo), bytes32(uint256(5)));
    }

    function testViewDataReadsSequentialSlots() public {
        bytes32 startSlot = bytes32(uint256(21));

        vm.store(address(kernel), startSlot, bytes32(uint256(101)));
        vm.store(address(kernel), _slotOffset(startSlot, 1), bytes32(uint256(202)));

        bytes memory data = kernel.viewData(startSlot, 2);

        assertEq(data, abi.encode(bytes32(uint256(101)), bytes32(uint256(202))));
    }

    function testViewDataReadsSingleSlot() public {
        bytes32 slot = bytes32(uint256(23));
        bytes32 value = bytes32(uint256(303));

        vm.store(address(kernel), slot, value);

        assertEq(kernel.viewData(slot), value);
    }

    function testViewDataReadsSlotArray() public {
        bytes32[] memory slots = new bytes32[](3);
        slots[0] = bytes32(uint256(41));
        slots[1] = bytes32(uint256(42));
        slots[2] = bytes32(uint256(43));

        vm.store(address(kernel), slots[0], bytes32(uint256(1001)));
        vm.store(address(kernel), slots[1], bytes32(uint256(1002)));
        vm.store(address(kernel), slots[2], bytes32(uint256(1003)));

        bytes32[] memory data = kernel.viewData(slots);

        assertEq(data.length, 3);
        assertEq(data[0], bytes32(uint256(1001)));
        assertEq(data[1], bytes32(uint256(1002)));
        assertEq(data[2], bytes32(uint256(1003)));
    }

    function testViewDataReturnsEmptyArrayForEmptySlotsInput() public view {
        bytes32[] memory slots = new bytes32[](0);

        bytes32[] memory data = kernel.viewData(slots);

        assertEq(data.length, 0);
    }

    function testViewDataReturnsEmptyBytesForZeroSlots() public view {
        bytes memory data = kernel.viewData(bytes32(uint256(21)), 0);

        assertEq(data, bytes(""));
    }

    function testViewDataRevertsOnOverflow() public {
        vm.expectRevert(Kernel.Kernel__SlotReadOverflow.selector);
        kernel.viewData(bytes32(uint256(1)), (type(uint256).max >> 5) + 1);
    }

    function testUpdateStateRevertsOnPartialWord() public {
        bytes memory data = hex"1234";

        controller.setPermissioned(WRITER, true);

        vm.expectRevert(Kernel.Kernel__InvalidSlotDataLength.selector);
        vm.prank(WRITER);
        kernel.updateState(bytes32(uint256(1)), data);
    }

    function testUpdateStateRevertsForUnauthorizedCaller() public {
        vm.expectRevert(Kernel.Kernel__InvalidCaller.selector);
        vm.prank(STRANGER);
        kernel.updateState(bytes32(uint256(1)), abi.encode(bytes32(uint256(123))));
    }

    function testUpdateStateSingleSlotRevertsForUnauthorizedCaller() public {
        vm.expectRevert(Kernel.Kernel__InvalidCaller.selector);
        vm.prank(STRANGER);
        kernel.updateState(bytes32(uint256(1)), bytes32(uint256(123)));
    }

    function testUpdateStateBatchRevertsForUnauthorizedCaller() public {
        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](1);
        calls[0] = IKernel.KernelCall({slot: bytes32(uint256(1)), data: bytes32(uint256(123))});

        vm.expectRevert(Kernel.Kernel__InvalidCaller.selector);
        vm.prank(STRANGER);
        kernel.updateState(calls);
    }

    function testAddSingleSlotRevertsForUnauthorizedCaller() public {
        vm.expectRevert(Kernel.Kernel__InvalidCaller.selector);
        vm.prank(STRANGER);
        kernel.add(bytes32(uint256(1)), bytes32(uint256(123)));
    }

    function testAddBatchRevertsForUnauthorizedCaller() public {
        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](1);
        calls[0] = IKernel.KernelCall({slot: bytes32(uint256(1)), data: bytes32(uint256(123))});

        vm.expectRevert(Kernel.Kernel__InvalidCaller.selector);
        vm.prank(STRANGER);
        kernel.add(calls);
    }

    function testSubSingleSlotRevertsForUnauthorizedCaller() public {
        vm.expectRevert(Kernel.Kernel__InvalidCaller.selector);
        vm.prank(STRANGER);
        kernel.sub(bytes32(uint256(1)), bytes32(uint256(123)));
    }

    function testSubBatchRevertsForUnauthorizedCaller() public {
        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](1);
        calls[0] = IKernel.KernelCall({slot: bytes32(uint256(1)), data: bytes32(uint256(123))});

        vm.expectRevert(Kernel.Kernel__InvalidCaller.selector);
        vm.prank(STRANGER);
        kernel.sub(calls);
    }

    function testUpdateStateRevertsAfterControllerRevokesCaller() public {
        controller.setPermissioned(WRITER, true);
        controller.setPermissioned(WRITER, false);

        vm.expectRevert(Kernel.Kernel__InvalidCaller.selector);
        vm.prank(WRITER);
        kernel.updateState(bytes32(uint256(1)), abi.encode(bytes32(uint256(123))));
    }

    function _slotOffset(bytes32 slot, uint256 offset) internal pure returns (bytes32) {
        return bytes32(uint256(slot) + offset);
    }
}
