///SPDX-License-Unlicensed
pragma solidity 0.8.34;

import {Vault} from "../src/Vault.sol";
import {Kernel} from "../src/Kernel.sol";
import {IKernel} from "../src/interfaces/IKernel.sol";
import {Test} from "forge-std/Test.sol";

contract CoreInvariantHandler is Test {
    uint256 internal constant SLOT_COUNT = 8;

    Kernel public immutable kernel;
    address public immutable controller;
    address public immutable writer;

    bytes32[8] internal expected;

    constructor(Kernel kernel_, address controller_, address writer_) {
        kernel = kernel_;
        controller = controller_;
        writer = writer_;
    }

    function expectedAt(uint256 index) external view returns (bytes32) {
        return expected[index];
    }

    function slotAt(uint256 index) public pure returns (bytes32) {
        return bytes32(index + 1);
    }

    function updateSingle(uint256 seed, bytes32 value) external {
        uint256 index = _index(seed);

        vm.prank(controller);
        kernel.updateState(slotAt(index), value);

        expected[index] = value;
    }

    function updateArray(uint256 seed, bytes32 firstValue, bytes32 secondValue, bytes32 thirdValue) external {
        uint256 firstIndex = _index(seed);
        uint256 secondIndex = _index(seed >> 8);
        uint256 thirdIndex = _index(seed >> 16);

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: slotAt(firstIndex), data: firstValue});
        calls[1] = IKernel.KernelCall({slot: slotAt(secondIndex), data: secondValue});
        calls[2] = IKernel.KernelCall({slot: slotAt(thirdIndex), data: thirdValue});

        vm.prank(controller);
        kernel.updateState(calls);

        expected[firstIndex] = firstValue;
        expected[secondIndex] = secondValue;
        expected[thirdIndex] = thirdValue;
    }

    function updateSlice(uint256 seed, uint8 rawCount, bytes32 firstValue, bytes32 secondValue, bytes32 thirdValue)
        external
    {
        uint256 wordCount = uint256(rawCount) % 4;
        uint256 startIndex = wordCount == 0 ? _index(seed) : seed % (SLOT_COUNT - wordCount + 1);
        bytes memory data;

        if (wordCount == 1) {
            data = abi.encodePacked(firstValue);
        } else if (wordCount == 2) {
            data = abi.encodePacked(firstValue, secondValue);
        } else if (wordCount == 3) {
            data = abi.encodePacked(firstValue, secondValue, thirdValue);
        }

        vm.prank(controller);
        kernel.updateState(slotAt(startIndex), data);

        if (wordCount > 0) expected[startIndex] = firstValue;
        if (wordCount > 1) expected[startIndex + 1] = secondValue;
        if (wordCount > 2) expected[startIndex + 2] = thirdValue;
    }

    function addSingle(uint256 seed, uint256 amount) external {
        uint256 index = _index(seed);
        uint256 current = uint256(expected[index]);

        if (amount > type(uint256).max - current) {
            vm.prank(writer);
            vm.expectRevert(Kernel.Kernel__AddOverflow.selector);
            kernel.add(slotAt(index), bytes32(amount));
            return;
        }

        vm.prank(writer);
        kernel.add(slotAt(index), bytes32(amount));

        expected[index] = bytes32(current + amount);
    }

    function subSingle(uint256 seed, uint256 amount) external {
        uint256 index = _index(seed);
        uint256 current = uint256(expected[index]);

        if (amount > current) {
            vm.prank(writer);
            vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
            kernel.sub(slotAt(index), bytes32(amount));
            return;
        }

        vm.prank(writer);
        kernel.sub(slotAt(index), bytes32(amount));

        expected[index] = bytes32(current - amount);
    }

    function addArray(uint256 seed, uint128 firstAmount, uint128 secondAmount, uint128 thirdAmount) external {
        uint256[3] memory indexes;
        uint256[3] memory amounts;
        bytes32[8] memory nextExpected = expected;

        indexes[0] = _index(seed);
        indexes[1] = _index(seed >> 8);
        indexes[2] = _index(seed >> 16);
        amounts[0] = uint256(firstAmount);
        amounts[1] = uint256(secondAmount);
        amounts[2] = uint256(thirdAmount);

        bool shouldRevert;
        for (uint256 i; i < 3;) {
            uint256 current = uint256(nextExpected[indexes[i]]);
            if (amounts[i] > type(uint256).max - current) {
                shouldRevert = true;
                break;
            }
            nextExpected[indexes[i]] = bytes32(current + amounts[i]);
            unchecked {
                ++i;
            }
        }

        IKernel.KernelCall[] memory calls = _calls(indexes, amounts);

        if (shouldRevert) {
            vm.prank(writer);
            vm.expectRevert(Kernel.Kernel__AddOverflow.selector);
            kernel.add(calls);
            return;
        }

        vm.prank(writer);
        kernel.add(calls);
        expected = nextExpected;
    }

    function subArray(uint256 seed, uint128 firstAmount, uint128 secondAmount, uint128 thirdAmount) external {
        uint256[3] memory indexes;
        uint256[3] memory amounts;
        bytes32[8] memory nextExpected = expected;

        indexes[0] = _index(seed);
        indexes[1] = _index(seed >> 8);
        indexes[2] = _index(seed >> 16);
        amounts[0] = uint256(firstAmount);
        amounts[1] = uint256(secondAmount);
        amounts[2] = uint256(thirdAmount);

        bool shouldRevert;
        for (uint256 i; i < 3;) {
            uint256 current = uint256(nextExpected[indexes[i]]);
            if (amounts[i] > current) {
                shouldRevert = true;
                break;
            }
            nextExpected[indexes[i]] = bytes32(current - amounts[i]);
            unchecked {
                ++i;
            }
        }

        IKernel.KernelCall[] memory calls = _calls(indexes, amounts);

        if (shouldRevert) {
            vm.prank(writer);
            vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
            kernel.sub(calls);
            return;
        }

        vm.prank(writer);
        kernel.sub(calls);
        expected = nextExpected;
    }

    function protectedSlotWrite(uint8 mode, bytes32 value) external {
        uint8 selectedMode = mode % 7;

        if (selectedMode == 0) {
            vm.prank(controller);
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.updateState(bytes32(0), value);
        } else if (selectedMode == 1) {
            IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](1);
            calls[0] = IKernel.KernelCall({slot: bytes32(0), data: value});

            vm.prank(controller);
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.updateState(calls);
        } else if (selectedMode == 2) {
            vm.prank(controller);
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.updateState(bytes32(0), abi.encodePacked(value));
        } else if (selectedMode == 3) {
            vm.prank(writer);
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.add(bytes32(0), value);
        } else if (selectedMode == 4) {
            IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](1);
            calls[0] = IKernel.KernelCall({slot: bytes32(0), data: value});

            vm.prank(writer);
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.add(calls);
        } else if (selectedMode == 5) {
            vm.prank(writer);
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.sub(bytes32(0), value);
        } else {
            IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](1);
            calls[0] = IKernel.KernelCall({slot: bytes32(0), data: value});

            vm.prank(writer);
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.sub(calls);
        }
    }

    function overflowingSliceWrite(bytes32 firstValue, bytes32 secondValue) external {
        bytes memory data = abi.encodePacked(firstValue, secondValue);

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__WriteOverflow.selector);
        kernel.updateState(bytes32(type(uint256).max), data);
    }

    function _index(uint256 seed) internal pure returns (uint256) {
        return seed % SLOT_COUNT;
    }

    function _calls(uint256[3] memory indexes, uint256[3] memory amounts)
        internal
        pure
        returns (IKernel.KernelCall[] memory calls)
    {
        calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: slotAt(indexes[0]), data: bytes32(amounts[0])});
        calls[1] = IKernel.KernelCall({slot: slotAt(indexes[1]), data: bytes32(amounts[1])});
        calls[2] = IKernel.KernelCall({slot: slotAt(indexes[2]), data: bytes32(amounts[2])});
    }
}

contract CoreInvariantTest is Test {
    Kernel kernel;
    Vault vault;
    CoreInvariantHandler handler;
    address controller = makeAddr("Controller");

    function setUp() public {
        kernel = new Kernel(controller);
        vault = new Vault(controller, address(kernel));

        vm.prank(controller);
        kernel.setAccountingWriter(address(vault));

        handler = new CoreInvariantHandler(kernel, controller, address(vault));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = CoreInvariantHandler.updateSingle.selector;
        selectors[1] = CoreInvariantHandler.updateArray.selector;
        selectors[2] = CoreInvariantHandler.updateSlice.selector;
        selectors[3] = CoreInvariantHandler.addSingle.selector;
        selectors[4] = CoreInvariantHandler.subSingle.selector;
        selectors[5] = CoreInvariantHandler.addArray.selector;
        selectors[6] = CoreInvariantHandler.subArray.selector;
        selectors[7] = CoreInvariantHandler.protectedSlotWrite.selector;
        selectors[8] = CoreInvariantHandler.overflowingSliceWrite.selector;

        excludeContract(address(kernel));
        excludeContract(address(vault));
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_accountingWriterCannotChange() public view {
        assertEq(kernel.accountingWriter(), address(vault));
        assertEq(kernel.viewData(bytes32(0)), bytes32(uint256(uint160(address(vault)))));
    }

    function invariant_trackedSlotsMatchModel() public view {
        for (uint256 i; i < 8;) {
            assertEq(kernel.viewData(handler.slotAt(i)), handler.expectedAt(i));
            unchecked {
                ++i;
            }
        }
    }

    function invariant_contiguousReadMatchesModel() public view {
        bytes memory actual = kernel.viewData(bytes32(uint256(1)), 8);
        bytes memory expectedData = abi.encodePacked(
            handler.expectedAt(0),
            handler.expectedAt(1),
            handler.expectedAt(2),
            handler.expectedAt(3),
            handler.expectedAt(4),
            handler.expectedAt(5),
            handler.expectedAt(6),
            handler.expectedAt(7)
        );

        assertEq(actual, expectedData);
    }

    function invariant_arbitraryReadMatchesModelInRequestedOrder() public view {
        bytes32[] memory slots = new bytes32[](5);
        slots[0] = handler.slotAt(2);
        slots[1] = handler.slotAt(0);
        slots[2] = handler.slotAt(2);
        slots[3] = handler.slotAt(7);
        slots[4] = handler.slotAt(0);

        bytes32[] memory data = kernel.viewData(slots);

        assertEq(data.length, slots.length);
        assertEq(data[0], handler.expectedAt(2));
        assertEq(data[1], handler.expectedAt(0));
        assertEq(data[2], handler.expectedAt(2));
        assertEq(data[3], handler.expectedAt(7));
        assertEq(data[4], handler.expectedAt(0));
    }

    function testFuzzUpdateSliceWriteOverflowReverts(uint8 rawWordCount, bytes32 a, bytes32 b, bytes32 c, bytes32 d)
        public
    {
        uint256 wordCount = bound(uint256(rawWordCount), 2, 4);
        uint256 start = type(uint256).max - wordCount + 2;
        bytes memory data;

        if (wordCount == 2) {
            data = abi.encodePacked(a, b);
        } else if (wordCount == 3) {
            data = abi.encodePacked(a, b, c);
        } else {
            data = abi.encodePacked(a, b, c, d);
        }

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__WriteOverflow.selector);
        kernel.updateState(bytes32(start), data);
    }

    function testFuzzUpdateSliceAtMaxWithOneWordSucceeds(bytes32 value) public {
        bytes32 startSlot = bytes32(type(uint256).max);

        vm.prank(controller);
        kernel.updateState(startSlot, abi.encodePacked(value));

        assertEq(kernel.viewData(startSlot), value);
        assertEq(kernel.accountingWriter(), address(vault));
    }

    function testFuzzUpdateArrayDuplicateSlotsLastWriteWins(bytes32 firstValue, bytes32 middleValue, bytes32 lastValue)
        public
    {
        bytes32 duplicateSlot = bytes32(uint256(1));
        bytes32 otherSlot = bytes32(uint256(2));

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: duplicateSlot, data: firstValue});
        calls[1] = IKernel.KernelCall({slot: otherSlot, data: middleValue});
        calls[2] = IKernel.KernelCall({slot: duplicateSlot, data: lastValue});

        vm.prank(controller);
        kernel.updateState(calls);

        assertEq(kernel.viewData(duplicateSlot), lastValue);
        assertEq(kernel.viewData(otherSlot), middleValue);
    }

    function testFuzzAddSubRoundTrip(uint8 rawSlot, uint128 startingValue, uint128 delta) public {
        bytes32 slot = bytes32(uint256((uint256(rawSlot) % 8) + 1));

        vm.prank(controller);
        kernel.updateState(slot, bytes32(uint256(startingValue)));

        vm.prank(address(vault));
        kernel.add(slot, bytes32(uint256(delta)));

        vm.prank(address(vault));
        kernel.sub(slot, bytes32(uint256(delta)));

        assertEq(uint256(kernel.viewData(slot)), uint256(startingValue));
    }

    function testFuzzProtectedSlotCannotBeWritten(bytes32 value, uint8 mode) public {
        uint8 selectedMode = mode % 3;

        if (selectedMode == 0) {
            vm.prank(controller);
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.updateState(bytes32(0), value);
        } else if (selectedMode == 1) {
            vm.prank(address(vault));
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.add(bytes32(0), value);
        } else {
            vm.prank(address(vault));
            vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
            kernel.sub(bytes32(0), value);
        }

        assertEq(kernel.accountingWriter(), address(vault));
        assertEq(kernel.viewData(bytes32(0)), bytes32(uint256(uint160(address(vault)))));
    }
}
