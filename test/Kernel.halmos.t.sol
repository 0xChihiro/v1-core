///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Kernel} from "../src/Kernel.sol";
import {IKernel} from "../src/interfaces/IKernel.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";

contract KernelHalmosTest is Test, SymTest {
    Kernel internal kernel;

    address internal constant CONTROLLER = address(0xC0117011e2);
    address internal constant VAULT = address(0xA11C0A11e2);
    bytes4 internal constant UPDATE_STATE_BYTES_SELECTOR = bytes4(keccak256("updateState(bytes32,bytes)"));
    bytes4 internal constant ADD_CALLS_SELECTOR = bytes4(keccak256("add((bytes32,bytes32)[])"));
    bytes4 internal constant SUB_CALLS_SELECTOR = bytes4(keccak256("sub((bytes32,bytes32)[])"));

    function setUp() public {
        kernel = new Kernel(CONTROLLER, VAULT);
    }

    function check_kernelSetAddSubRoundTrip() public {
        uint256 startingValue = svm.createUint(128, "kernel starting value");
        uint256 delta = svm.createUint(128, "kernel delta");

        _assertSetAddSubRoundTrip(bytes32(uint256(1)), startingValue, delta);
    }

    function check_kernelContiguousWriteReadsBackEachWord() public {
        bytes32 first = svm.createBytes32("kernel contiguous first");
        bytes32 second = svm.createBytes32("kernel contiguous second");
        bytes32 third = svm.createBytes32("kernel contiguous third");

        _assertContiguousWriteReadsBackEachWord(bytes32(uint256(100)), first, second, third);
    }

    function check_kernelAddBatchRevertIsAtomic() public {
        uint256 startingValue = svm.createUint(128, "kernel atomic add starting value");
        uint256 delta = svm.createUint(128, "kernel atomic add delta");

        _assertAddBatchRevertIsAtomic(bytes32(uint256(200)), bytes32(uint256(201)), startingValue, delta);
    }

    function check_kernelSubBatchRevertIsAtomic() public {
        uint256 startingValue = svm.createUint(128, "kernel atomic sub starting value");
        uint256 delta = svm.createUint(128, "kernel atomic sub delta");

        vm.assume(delta <= startingValue);
        _assertSubBatchRevertIsAtomic(bytes32(uint256(300)), bytes32(uint256(301)), startingValue, delta);
    }

    function check_kernelOverflowingSliceWriteDoesNotWriteBoundarySlot() public {
        bytes32 first = svm.createBytes32("kernel overflow slice first");
        bytes32 second = svm.createBytes32("kernel overflow slice second");

        _assertOverflowingSliceWriteDoesNotWriteBoundarySlot(first, second);
    }

    function testConcreteKernelSetAddSubRoundTrip() public {
        _assertSetAddSubRoundTrip(bytes32(uint256(7)), 123, 456);
    }

    function testConcreteKernelContiguousWriteReadsBackEachWord() public {
        _assertContiguousWriteReadsBackEachWord(
            bytes32(uint256(11)), bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))
        );
    }

    function testConcreteKernelAddBatchRevertIsAtomic() public {
        _assertAddBatchRevertIsAtomic(bytes32(uint256(1)), bytes32(uint256(2)), 100, 25);
    }

    function testConcreteKernelSubBatchRevertIsAtomic() public {
        _assertSubBatchRevertIsAtomic(bytes32(uint256(3)), bytes32(uint256(4)), 100, 25);
    }

    function testConcreteKernelOverflowingSliceWriteDoesNotWriteBoundarySlot() public {
        _assertOverflowingSliceWriteDoesNotWriteBoundarySlot(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function _assertSetAddSubRoundTrip(bytes32 slot, uint256 startingValue, uint256 delta) internal {
        vm.prank(CONTROLLER);
        kernel.updateState(slot, bytes32(startingValue));

        vm.prank(VAULT);
        kernel.add(slot, bytes32(delta));
        assertEq(uint256(kernel.viewData(slot)), startingValue + delta);

        vm.prank(VAULT);
        kernel.sub(slot, bytes32(delta));
        assertEq(uint256(kernel.viewData(slot)), startingValue);
        assertEq(kernel.accountingWriter(), VAULT);
    }

    function _assertContiguousWriteReadsBackEachWord(bytes32 startSlot, bytes32 first, bytes32 second, bytes32 third)
        internal
    {
        bytes memory data = abi.encodePacked(first, second, third);

        vm.prank(CONTROLLER);
        kernel.updateState(startSlot, data);

        assertEq(kernel.viewData(startSlot, 3), data);
        assertEq(kernel.viewData(startSlot), first);
        assertEq(kernel.viewData(bytes32(uint256(startSlot) + 1)), second);
        assertEq(kernel.viewData(bytes32(uint256(startSlot) + 2)), third);

        bytes32[] memory slots = new bytes32[](5);
        slots[0] = bytes32(uint256(startSlot) + 2);
        slots[1] = startSlot;
        slots[2] = bytes32(uint256(startSlot) + 1);
        slots[3] = bytes32(uint256(startSlot) + 2);
        slots[4] = startSlot;

        bytes32[] memory readBack = kernel.viewData(slots);
        assertEq(readBack.length, slots.length);
        assertEq(readBack[0], third);
        assertEq(readBack[1], first);
        assertEq(readBack[2], second);
        assertEq(readBack[3], third);
        assertEq(readBack[4], first);
    }

    function _assertAddBatchRevertIsAtomic(
        bytes32 firstSlot,
        bytes32 overflowSlot,
        uint256 startingValue,
        uint256 delta
    ) internal {
        vm.startPrank(CONTROLLER);
        kernel.updateState(firstSlot, bytes32(startingValue));
        kernel.updateState(overflowSlot, bytes32(type(uint256).max));
        vm.stopPrank();

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);
        calls[0] = IKernel.KernelCall({slot: firstSlot, data: bytes32(delta)});
        calls[1] = IKernel.KernelCall({slot: overflowSlot, data: bytes32(uint256(1))});

        vm.prank(VAULT);
        (bool success, bytes memory returnData) =
            address(kernel).call(abi.encodeWithSelector(ADD_CALLS_SELECTOR, calls));

        assertFalse(success);
        assertEq(_revertSelector(returnData), Kernel.Kernel__AddOverflow.selector);
        assertEq(uint256(kernel.viewData(firstSlot)), startingValue);
        assertEq(uint256(kernel.viewData(overflowSlot)), type(uint256).max);
    }

    function _assertSubBatchRevertIsAtomic(
        bytes32 firstSlot,
        bytes32 underflowSlot,
        uint256 startingValue,
        uint256 delta
    ) internal {
        vm.startPrank(CONTROLLER);
        kernel.updateState(firstSlot, bytes32(startingValue));
        kernel.updateState(underflowSlot, bytes32(uint256(0)));
        vm.stopPrank();

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);
        calls[0] = IKernel.KernelCall({slot: firstSlot, data: bytes32(delta)});
        calls[1] = IKernel.KernelCall({slot: underflowSlot, data: bytes32(uint256(1))});

        vm.prank(VAULT);
        (bool success, bytes memory returnData) =
            address(kernel).call(abi.encodeWithSelector(SUB_CALLS_SELECTOR, calls));

        assertFalse(success);
        assertEq(_revertSelector(returnData), Kernel.Kernel__SubUnderflow.selector);
        assertEq(uint256(kernel.viewData(firstSlot)), startingValue);
        assertEq(uint256(kernel.viewData(underflowSlot)), 0);
    }

    function _assertOverflowingSliceWriteDoesNotWriteBoundarySlot(bytes32 first, bytes32 second) internal {
        bytes32 boundarySlot = bytes32(type(uint256).max);
        bytes32 beforeBoundary = kernel.viewData(boundarySlot);

        vm.prank(CONTROLLER);
        (bool success, bytes memory returnData) = address(kernel)
            .call(abi.encodeWithSelector(UPDATE_STATE_BYTES_SELECTOR, boundarySlot, abi.encodePacked(first, second)));

        assertFalse(success);
        assertEq(_revertSelector(returnData), Kernel.Kernel__WriteOverflow.selector);
        assertEq(kernel.viewData(boundarySlot), beforeBoundary);
        assertEq(kernel.accountingWriter(), VAULT);
    }

    function _revertSelector(bytes memory returnData) internal pure returns (bytes4 selector) {
        assert(returnData.length >= 4);
        assembly ("memory-safe") {
            selector := mload(add(returnData, 0x20))
        }
    }
}
