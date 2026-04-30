///SPDX-License-Unlicensed
pragma solidity 0.8.34;

import {Vault} from "../src/Vault.sol";
import {Kernel} from "../src/Kernel.sol";
import {IKernel} from "../src/interfaces/IKernel.sol";
import {Test} from "forge-std/Test.sol";

contract CoreTest is Test {
    Vault vault;
    Kernel kernel;
    address controller = makeAddr("Controller");

    function setUp() public {
        vm.expectRevert(Kernel.Kernel__ControllerZeroAddress.selector);
        kernel = new Kernel(address(0));

        kernel = new Kernel(controller);
        vault = new Vault(controller, address(kernel));
    }

    function testSetAccountWriter() public {
        vm.expectRevert(Kernel.Kernel__OnlyController.selector);
        kernel.setAccountingWriter(address(vault));

        vm.startPrank(controller);
        vm.expectRevert(Kernel.Kernel__AccountingWriterZeroAddress.selector);
        kernel.setAccountingWriter(address(0));
        vm.stopPrank();

        vm.prank(controller);
        kernel.setAccountingWriter(address(vault));

        vm.startPrank(controller);
        vm.expectRevert(Kernel.Kernel__AccountingWriterAlreadySet.selector);
        kernel.setAccountingWriter(address(vault));
        vm.stopPrank();

        address writer = kernel.accountingWriter();
        assertEq(address(vault), writer);
    }

    function testAccountingWriterSlotCannotBeWrittenThroughStateApi() public {
        bytes32 protectedSlot = bytes32(0);
        bytes32 protectedValue = bytes32(uint256(uint160(makeAddr("BadAccountingWriter"))));

        vm.prank(controller);
        kernel.setAccountingWriter(address(vault));

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
        kernel.updateState(protectedSlot, protectedValue);

        IKernel.KernelCall[] memory updateCalls = new IKernel.KernelCall[](1);
        updateCalls[0] = IKernel.KernelCall({slot: protectedSlot, data: protectedValue});

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
        kernel.updateState(updateCalls);

        bytes memory sliceData = abi.encodePacked(protectedValue, keccak256("next slot value"));

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
        kernel.updateState(protectedSlot, sliceData);

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
        kernel.add(protectedSlot, bytes32(uint256(1)));

        IKernel.KernelCall[] memory addCalls = new IKernel.KernelCall[](1);
        addCalls[0] = IKernel.KernelCall({slot: protectedSlot, data: bytes32(uint256(1))});

        vm.prank(address(vault));
        vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
        kernel.add(addCalls);

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
        kernel.sub(protectedSlot, bytes32(uint256(1)));

        IKernel.KernelCall[] memory subCalls = new IKernel.KernelCall[](1);
        subCalls[0] = IKernel.KernelCall({slot: protectedSlot, data: bytes32(uint256(1))});

        vm.prank(address(vault));
        vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
        kernel.sub(subCalls);

        assertEq(kernel.accountingWriter(), address(vault));
    }

    function testUpdateStateArrayRevertsAtomically() public {
        bytes32 firstSlot = keccak256("first atomic update state slot");
        bytes32 thirdSlot = keccak256("third atomic update state slot");
        bytes32 firstValue = keccak256("first atomic update state value");
        bytes32 protectedValue = bytes32(uint256(uint160(makeAddr("BadAccountingWriter"))));
        bytes32 thirdValue = keccak256("third atomic update state value");

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: firstSlot, data: firstValue});
        calls[1] = IKernel.KernelCall({slot: bytes32(0), data: protectedValue});
        calls[2] = IKernel.KernelCall({slot: thirdSlot, data: thirdValue});

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__ProtectedSlot.selector);
        kernel.updateState(calls);

        assertEq(kernel.viewData(firstSlot), bytes32(0));
        assertEq(kernel.viewData(thirdSlot), bytes32(0));
        assertEq(kernel.accountingWriter(), address(0));
    }

    function testUpdateStateArrayDuplicateSlotsLastWriteWins() public {
        bytes32 firstSlot = keccak256("first duplicate update state slot");
        bytes32 secondSlot = keccak256("second duplicate update state slot");
        bytes32 firstSlotLatestValue = keccak256("first duplicate update state latest value");
        bytes32 secondSlotLatestValue = keccak256("second duplicate update state latest value");

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](5);
        calls[0] = IKernel.KernelCall({slot: firstSlot, data: keccak256("first slot first value")});
        calls[1] = IKernel.KernelCall({slot: secondSlot, data: keccak256("second slot first value")});
        calls[2] = IKernel.KernelCall({slot: firstSlot, data: keccak256("first slot second value")});
        calls[3] = IKernel.KernelCall({slot: secondSlot, data: secondSlotLatestValue});
        calls[4] = IKernel.KernelCall({slot: firstSlot, data: firstSlotLatestValue});

        vm.prank(controller);
        kernel.updateState(calls);

        assertEq(kernel.viewData(firstSlot), firstSlotLatestValue);
        assertEq(kernel.viewData(secondSlot), secondSlotLatestValue);
    }

    function testUpdateStateOverwritesExistingValues() public {
        bytes32 singleSlot = keccak256("single overwrite slot");
        bytes32 arrayFirstSlot = keccak256("array first overwrite slot");
        bytes32 arraySecondSlot = keccak256("array second overwrite slot");
        bytes32 sliceStartSlot = bytes32(uint256(500));
        bytes32 sliceSecondSlot = bytes32(uint256(501));

        bytes32 singleLatestValue = keccak256("single overwrite latest value");
        bytes32 arrayFirstLatestValue = keccak256("array first overwrite latest value");
        bytes32 sliceFirstLatestValue = keccak256("slice first overwrite latest value");
        bytes memory sliceData = abi.encodePacked(sliceFirstLatestValue, bytes32(0));

        vm.startPrank(controller);
        kernel.updateState(singleSlot, keccak256("single overwrite old value"));
        kernel.updateState(singleSlot, singleLatestValue);
        kernel.updateState(singleSlot, bytes32(0));

        kernel.updateState(arrayFirstSlot, keccak256("array first overwrite old value"));
        kernel.updateState(arraySecondSlot, keccak256("array second overwrite old value"));

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);
        calls[0] = IKernel.KernelCall({slot: arrayFirstSlot, data: arrayFirstLatestValue});
        calls[1] = IKernel.KernelCall({slot: arraySecondSlot, data: bytes32(0)});
        kernel.updateState(calls);

        kernel.updateState(sliceStartSlot, keccak256("slice first overwrite old value"));
        kernel.updateState(sliceSecondSlot, keccak256("slice second overwrite old value"));
        kernel.updateState(sliceStartSlot, sliceData);
        vm.stopPrank();

        assertEq(kernel.viewData(singleSlot), bytes32(0));
        assertEq(kernel.viewData(arrayFirstSlot), arrayFirstLatestValue);
        assertEq(kernel.viewData(arraySecondSlot), bytes32(0));
        assertEq(kernel.viewData(sliceStartSlot), sliceFirstLatestValue);
        assertEq(kernel.viewData(sliceSecondSlot), bytes32(0));
        assertEq(kernel.viewData(sliceStartSlot, 2), sliceData);
    }

    function testUpdateStateSingle() public {
        bytes32 slot = keccak256("random slot");
        bytes32 data = keccak256("random data");

        vm.expectRevert(Kernel.Kernel__OnlyController.selector);
        kernel.updateState(slot, data);

        vm.prank(controller);
        kernel.updateState(slot, data);

        bytes32 returnData = kernel.viewData(slot);
        assertEq(returnData, data);
    }

    function testAddSingle(uint256 value) public {
        vm.assume(value != 0);
        uint256 overflow = type(uint256).max;
        vm.prank(controller);
        kernel.setAccountingWriter(address(vault));

        bytes32 slot = keccak256("random add slot");
        vm.expectRevert(Kernel.Kernel__OnlyAccountingWriter.selector);
        kernel.add(slot, bytes32(value));

        vm.prank(controller);
        kernel.add(slot, bytes32(value));
        uint256 data = uint256(kernel.viewData(slot));
        assertEq(data, value);

        vm.startPrank(address(vault));
        vm.expectRevert(Kernel.Kernel__AddOverflow.selector);
        kernel.add(slot, bytes32(overflow));
        kernel.add(bytes32(uint256(1)), bytes32(value));
        vm.stopPrank();

        uint256 storedData = uint256(kernel.viewData(bytes32(uint256(1))));
        assertEq(value, storedData);
    }

    /*
        1. Ensure that the can cannot be from someone who is not the controller or account writer
        2. Ensure that if any of the slots overflow it reverts.
        3. Ensure that if the slot already has data in it, the updated data reflects the addition.
        4. Ensure that blank slots hold the passed value.
        5. Ensure that all slots hold the correct values.
    */
    function testAddMultiple() public {
        vm.prank(controller);
        kernel.setAccountingWriter(address(vault));

        bytes32 existingSlot = keccak256("existing add multiple slot");
        bytes32 blankSlot = keccak256("blank add multiple slot");
        bytes32 secondBlankSlot = keccak256("second blank add multiple slot");
        bytes32 overflowSlot = keccak256("overflow add multiple slot");

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: existingSlot, data: bytes32(uint256(25))});
        calls[1] = IKernel.KernelCall({slot: blankSlot, data: bytes32(uint256(50))});
        calls[2] = IKernel.KernelCall({slot: secondBlankSlot, data: bytes32(uint256(75))});

        vm.expectRevert(Kernel.Kernel__OnlyAccountingWriter.selector);
        kernel.add(calls);

        vm.prank(controller);
        kernel.updateState(existingSlot, bytes32(uint256(100)));
        vm.prank(controller);
        kernel.updateState(overflowSlot, bytes32(type(uint256).max));

        IKernel.KernelCall[] memory overflowCalls = new IKernel.KernelCall[](2);
        overflowCalls[0] = IKernel.KernelCall({slot: blankSlot, data: bytes32(uint256(1))});
        overflowCalls[1] = IKernel.KernelCall({slot: overflowSlot, data: bytes32(uint256(1))});

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__AddOverflow.selector);
        kernel.add(overflowCalls);

        assertEq(uint256(kernel.viewData(blankSlot)), 0);
        assertEq(uint256(kernel.viewData(overflowSlot)), type(uint256).max);

        vm.prank(address(vault));
        kernel.add(calls);

        assertEq(uint256(kernel.viewData(existingSlot)), 125);
        assertEq(uint256(kernel.viewData(blankSlot)), 50);
        assertEq(uint256(kernel.viewData(secondBlankSlot)), 75);
    }

    function testAddMultipleRevertsAtomically() public {
        bytes32 firstSlot = keccak256("first atomic add slot");
        bytes32 overflowSlot = keccak256("overflow atomic add slot");
        bytes32 thirdSlot = keccak256("third atomic add slot");

        vm.startPrank(controller);
        kernel.setAccountingWriter(address(vault));
        kernel.updateState(firstSlot, bytes32(uint256(100)));
        kernel.updateState(overflowSlot, bytes32(type(uint256).max));
        vm.stopPrank();

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: firstSlot, data: bytes32(uint256(25))});
        calls[1] = IKernel.KernelCall({slot: overflowSlot, data: bytes32(uint256(1))});
        calls[2] = IKernel.KernelCall({slot: thirdSlot, data: bytes32(uint256(50))});

        vm.prank(address(vault));
        vm.expectRevert(Kernel.Kernel__AddOverflow.selector);
        kernel.add(calls);

        assertEq(uint256(kernel.viewData(firstSlot)), 100);
        assertEq(uint256(kernel.viewData(overflowSlot)), type(uint256).max);
        assertEq(uint256(kernel.viewData(thirdSlot)), 0);
    }

    function testAddZeroValueIsNoOp() public {
        bytes32 existingSlot = keccak256("existing add zero slot");
        bytes32 blankSlot = keccak256("blank add zero slot");

        vm.startPrank(controller);
        kernel.setAccountingWriter(address(vault));
        kernel.updateState(existingSlot, bytes32(uint256(100)));
        vm.stopPrank();

        vm.prank(address(vault));
        kernel.add(existingSlot, bytes32(0));

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);
        calls[0] = IKernel.KernelCall({slot: existingSlot, data: bytes32(0)});
        calls[1] = IKernel.KernelCall({slot: blankSlot, data: bytes32(0)});

        vm.prank(address(vault));
        kernel.add(calls);

        assertEq(uint256(kernel.viewData(existingSlot)), 100);
        assertEq(uint256(kernel.viewData(blankSlot)), 0);
    }

    function testAddMultipleDuplicateSlotsApplyInOrder() public {
        bytes32 duplicateSlot = keccak256("duplicate add slot");
        bytes32 otherSlot = keccak256("other duplicate add slot");

        vm.startPrank(controller);
        kernel.setAccountingWriter(address(vault));
        kernel.updateState(duplicateSlot, bytes32(uint256(10)));
        vm.stopPrank();

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: duplicateSlot, data: bytes32(uint256(5))});
        calls[1] = IKernel.KernelCall({slot: otherSlot, data: bytes32(uint256(1))});
        calls[2] = IKernel.KernelCall({slot: duplicateSlot, data: bytes32(uint256(7))});

        vm.prank(address(vault));
        kernel.add(calls);

        assertEq(uint256(kernel.viewData(duplicateSlot)), 22);
        assertEq(uint256(kernel.viewData(otherSlot)), 1);
    }

    function testAddMultipleDuplicateSlotOverflowLeavesValueUnchanged() public {
        bytes32 duplicateSlot = keccak256("duplicate add overflow slot");

        vm.startPrank(controller);
        kernel.setAccountingWriter(address(vault));
        kernel.updateState(duplicateSlot, bytes32(type(uint256).max - 5));
        vm.stopPrank();

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);
        calls[0] = IKernel.KernelCall({slot: duplicateSlot, data: bytes32(uint256(4))});
        calls[1] = IKernel.KernelCall({slot: duplicateSlot, data: bytes32(uint256(2))});

        vm.prank(address(vault));
        vm.expectRevert(Kernel.Kernel__AddOverflow.selector);
        kernel.add(calls);

        assertEq(uint256(kernel.viewData(duplicateSlot)), type(uint256).max - 5);
    }

    /*
        1. Ensure that the call can not be completed if the caller is not the controller or account writer.
        2. Ensure it works for the controller.
        3. Ensure it works for the account writer.
        4. Ensure that if a value will underflow it reverts.
    */
    function testSubSingle(uint128 value) public {
        vm.prank(controller);
        kernel.setAccountingWriter(address(vault));

        vm.assume(value != 0);
        bytes32 slot = keccak256("sub slot");
        vm.expectRevert(Kernel.Kernel__OnlyAccountingWriter.selector);
        kernel.sub(slot, bytes32(bytes16(value)));

        vm.startPrank(controller);
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        kernel.sub(slot, bytes32(bytes16(value)));
        kernel.add(slot, bytes32(uint256(value) * 2));
        vm.stopPrank();

        vm.prank(address(vault));
        kernel.sub(slot, bytes32(uint256(value)));

        uint256 storedValue = uint256(kernel.viewData(slot));

        assertEq(uint256(value), storedValue);
    }

    /*
        1. Ensure that the call can not be completed if the caller is not the controller or account writer.
        2. Ensure it works for the controller.
        3. Ensure it works for the account writer.
        4. Ensure that if a value will underflow it reverts.
        5. Ensure that slots that already have values stored in them show that they have been updated
    */
    function testSubMultiple() public {
        vm.prank(controller);
        kernel.setAccountingWriter(address(vault));

        bytes32 firstSlot = keccak256("first sub multiple slot");
        bytes32 secondSlot = keccak256("second sub multiple slot");
        bytes32 thirdSlot = keccak256("third sub multiple slot");

        vm.startPrank(controller);
        kernel.updateState(firstSlot, bytes32(uint256(100)));
        kernel.updateState(secondSlot, bytes32(uint256(200)));
        kernel.updateState(thirdSlot, bytes32(uint256(300)));
        vm.stopPrank();

        IKernel.KernelCall[] memory controllerCalls = new IKernel.KernelCall[](2);
        controllerCalls[0] = IKernel.KernelCall({slot: firstSlot, data: bytes32(uint256(40))});
        controllerCalls[1] = IKernel.KernelCall({slot: secondSlot, data: bytes32(uint256(75))});

        vm.expectRevert(Kernel.Kernel__OnlyAccountingWriter.selector);
        kernel.sub(controllerCalls);

        vm.prank(controller);
        kernel.sub(controllerCalls);

        assertEq(uint256(kernel.viewData(firstSlot)), 60);
        assertEq(uint256(kernel.viewData(secondSlot)), 125);

        IKernel.KernelCall[] memory writerCalls = new IKernel.KernelCall[](2);
        writerCalls[0] = IKernel.KernelCall({slot: firstSlot, data: bytes32(uint256(10))});
        writerCalls[1] = IKernel.KernelCall({slot: thirdSlot, data: bytes32(uint256(125))});

        vm.prank(address(vault));
        kernel.sub(writerCalls);

        assertEq(uint256(kernel.viewData(firstSlot)), 50);
        assertEq(uint256(kernel.viewData(thirdSlot)), 175);

        IKernel.KernelCall[] memory underflowCalls = new IKernel.KernelCall[](2);
        underflowCalls[0] = IKernel.KernelCall({slot: firstSlot, data: bytes32(uint256(25))});
        underflowCalls[1] = IKernel.KernelCall({slot: secondSlot, data: bytes32(uint256(126))});

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        kernel.sub(underflowCalls);

        assertEq(uint256(kernel.viewData(firstSlot)), 50);
        assertEq(uint256(kernel.viewData(secondSlot)), 125);
    }

    function testSubMultipleRevertsAtomically() public {
        bytes32 firstSlot = keccak256("first atomic sub slot");
        bytes32 underflowSlot = keccak256("underflow atomic sub slot");
        bytes32 thirdSlot = keccak256("third atomic sub slot");

        vm.startPrank(controller);
        kernel.setAccountingWriter(address(vault));
        kernel.updateState(firstSlot, bytes32(uint256(100)));
        kernel.updateState(underflowSlot, bytes32(uint256(10)));
        kernel.updateState(thirdSlot, bytes32(uint256(200)));
        vm.stopPrank();

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: firstSlot, data: bytes32(uint256(25))});
        calls[1] = IKernel.KernelCall({slot: underflowSlot, data: bytes32(uint256(11))});
        calls[2] = IKernel.KernelCall({slot: thirdSlot, data: bytes32(uint256(50))});

        vm.prank(address(vault));
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        kernel.sub(calls);

        assertEq(uint256(kernel.viewData(firstSlot)), 100);
        assertEq(uint256(kernel.viewData(underflowSlot)), 10);
        assertEq(uint256(kernel.viewData(thirdSlot)), 200);
    }

    function testSubZeroValueIsNoOp() public {
        bytes32 existingSlot = keccak256("existing sub zero slot");
        bytes32 blankSlot = keccak256("blank sub zero slot");

        vm.startPrank(controller);
        kernel.setAccountingWriter(address(vault));
        kernel.updateState(existingSlot, bytes32(uint256(100)));
        vm.stopPrank();

        vm.prank(address(vault));
        kernel.sub(existingSlot, bytes32(0));

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);
        calls[0] = IKernel.KernelCall({slot: existingSlot, data: bytes32(0)});
        calls[1] = IKernel.KernelCall({slot: blankSlot, data: bytes32(0)});

        vm.prank(address(vault));
        kernel.sub(calls);

        assertEq(uint256(kernel.viewData(existingSlot)), 100);
        assertEq(uint256(kernel.viewData(blankSlot)), 0);
    }

    function testSubMultipleDuplicateSlotsApplyInOrder() public {
        bytes32 duplicateSlot = keccak256("duplicate sub slot");
        bytes32 otherSlot = keccak256("other duplicate sub slot");

        vm.startPrank(controller);
        kernel.setAccountingWriter(address(vault));
        kernel.updateState(duplicateSlot, bytes32(uint256(20)));
        kernel.updateState(otherSlot, bytes32(uint256(10)));
        vm.stopPrank();

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: duplicateSlot, data: bytes32(uint256(5))});
        calls[1] = IKernel.KernelCall({slot: otherSlot, data: bytes32(uint256(4))});
        calls[2] = IKernel.KernelCall({slot: duplicateSlot, data: bytes32(uint256(7))});

        vm.prank(address(vault));
        kernel.sub(calls);

        assertEq(uint256(kernel.viewData(duplicateSlot)), 8);
        assertEq(uint256(kernel.viewData(otherSlot)), 6);
    }

    function testSubMultipleDuplicateSlotUnderflowLeavesValueUnchanged() public {
        bytes32 duplicateSlot = keccak256("duplicate sub underflow slot");

        vm.startPrank(controller);
        kernel.setAccountingWriter(address(vault));
        kernel.updateState(duplicateSlot, bytes32(uint256(10)));
        vm.stopPrank();

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);
        calls[0] = IKernel.KernelCall({slot: duplicateSlot, data: bytes32(uint256(6))});
        calls[1] = IKernel.KernelCall({slot: duplicateSlot, data: bytes32(uint256(5))});

        vm.prank(address(vault));
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        kernel.sub(calls);

        assertEq(uint256(kernel.viewData(duplicateSlot)), 10);
    }

    /*
        1. Calls should only be written by the controller.
        2. Calls should override any data that may have been in the slot before hand
        3. Latest state should reflect the latest calls.
        4. Untouch slots should not be effected.
    */
    function testUpdateStateArray() public {
        bytes32 firstSlot = keccak256("first update state array slot");
        bytes32 secondSlot = keccak256("second update state array slot");
        bytes32 thirdSlot = keccak256("third update state array slot");
        bytes32 untouchedSlot = keccak256("untouched update state array slot");

        bytes32 firstValue = keccak256("first update state array value");
        bytes32 secondValue = keccak256("second update state array value");
        bytes32 thirdValue = keccak256("third update state array value");
        bytes32 untouchedValue = keccak256("untouched update state array value");

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: firstSlot, data: firstValue});
        calls[1] = IKernel.KernelCall({slot: secondSlot, data: secondValue});
        calls[2] = IKernel.KernelCall({slot: thirdSlot, data: thirdValue});

        vm.expectRevert(Kernel.Kernel__OnlyController.selector);
        kernel.updateState(calls);

        vm.startPrank(controller);
        kernel.updateState(firstSlot, keccak256("old first update state array value"));
        kernel.updateState(untouchedSlot, untouchedValue);
        kernel.updateState(calls);
        vm.stopPrank();

        assertEq(kernel.viewData(firstSlot), firstValue);
        assertEq(kernel.viewData(secondSlot), secondValue);
        assertEq(kernel.viewData(thirdSlot), thirdValue);
        assertEq(kernel.viewData(untouchedSlot), untouchedValue);

        bytes32 latestFirstValue = keccak256("latest first update state array value");
        bytes32 latestThirdValue = keccak256("latest third update state array value");
        IKernel.KernelCall[] memory latestCalls = new IKernel.KernelCall[](2);
        latestCalls[0] = IKernel.KernelCall({slot: firstSlot, data: latestFirstValue});
        latestCalls[1] = IKernel.KernelCall({slot: thirdSlot, data: latestThirdValue});

        vm.prank(controller);
        kernel.updateState(latestCalls);

        assertEq(kernel.viewData(firstSlot), latestFirstValue);
        assertEq(kernel.viewData(secondSlot), secondValue);
        assertEq(kernel.viewData(thirdSlot), latestThirdValue);
        assertEq(kernel.viewData(untouchedSlot), untouchedValue);
    }

    /*
        1. Call should only be made by the controller.
        2. Data should be in 32 byte word length
        3. Should effectively write 32 bytes of data in each slot, overwritting data if it exists.
        4. If data is spread across 2 slots it should be able to reflect that in the
        way it is stored. Ie strings or something like that.
    */
    function testUpdateStateSlice() public {
        bytes32 startSlot = bytes32(uint256(100));
        bytes32 secondSlot = bytes32(uint256(101));
        bytes32 untouchedSlot = bytes32(uint256(102));

        bytes32 firstWord = bytes32("abcdefghijklmnopqrstuvwxyz123456");
        bytes32 secondWord = bytes32("ABCDEFGHIJKLMNOPQRSTUVWXYZ654321");
        bytes32 untouchedValue = keccak256("untouched update state slice value");
        bytes memory data = abi.encodePacked(firstWord, secondWord);
        bytes memory invalidData = hex"01";

        vm.expectRevert(Kernel.Kernel__OnlyController.selector);
        kernel.updateState(startSlot, data);

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__InvalidSlotDataLength.selector);
        kernel.updateState(startSlot, invalidData);

        vm.startPrank(controller);
        kernel.updateState(startSlot, keccak256("old first update state slice value"));
        kernel.updateState(secondSlot, keccak256("old second update state slice value"));
        kernel.updateState(untouchedSlot, untouchedValue);
        kernel.updateState(startSlot, data);
        vm.stopPrank();

        assertEq(kernel.viewData(startSlot), firstWord);
        assertEq(kernel.viewData(secondSlot), secondWord);
        assertEq(kernel.viewData(untouchedSlot), untouchedValue);
        assertEq(kernel.viewData(startSlot, 2), data);
    }

    function testUpdateStateSliceRevertsOnWriteOverflow() public {
        bytes32 startSlot = bytes32(type(uint256).max);
        bytes memory data = abi.encodePacked(
            keccak256("first overflowing update state slice value"),
            keccak256("second overflowing update state slice value")
        );

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__WriteOverflow.selector);
        kernel.updateState(startSlot, data);
    }

    /*
        1. Anyone can call
        2. Show read n amount of continious slots and accurately return data
        3. Data should be able to be decoded into it original form if encoded
    */
    function testViewDataNSlots() public {
        bytes32 startSlot = bytes32(uint256(200));
        uint256 expectedAmount = 123;
        address expectedAccount = makeAddr("ViewDataAccount");
        bytes32 expectedHash = keccak256("view data n slots hash");
        bytes memory data = abi.encode(expectedAmount, expectedAccount, expectedHash);

        vm.prank(controller);
        kernel.updateState(startSlot, data);

        address viewer = makeAddr("ViewDataNSlotsViewer");
        vm.prank(viewer);
        bytes memory returnedData = kernel.viewData(startSlot, 3);

        assertEq(returnedData, data);

        (uint256 returnedAmount, address returnedAccount, bytes32 returnedHash) =
            abi.decode(returnedData, (uint256, address, bytes32));
        assertEq(returnedAmount, expectedAmount);
        assertEq(returnedAccount, expectedAccount);
        assertEq(returnedHash, expectedHash);
    }

    /*
        1. Anyone can call
        2. Should read accurately n abitrary slots
        3. Should return a equal length array to the slots asked for.
    */
    function testViewDataSlotArray() public {
        bytes32 firstSlot = keccak256("first arbitrary view slot");
        bytes32 secondSlot = keccak256("second arbitrary view slot");
        bytes32 thirdSlot = keccak256("third arbitrary view slot");
        bytes32 blankSlot = keccak256("blank arbitrary view slot");

        bytes32 firstValue = keccak256("first arbitrary view value");
        bytes32 secondValue = keccak256("second arbitrary view value");
        bytes32 thirdValue = keccak256("third arbitrary view value");

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](3);
        calls[0] = IKernel.KernelCall({slot: firstSlot, data: firstValue});
        calls[1] = IKernel.KernelCall({slot: secondSlot, data: secondValue});
        calls[2] = IKernel.KernelCall({slot: thirdSlot, data: thirdValue});

        vm.prank(controller);
        kernel.updateState(calls);

        bytes32[] memory slots = new bytes32[](4);
        slots[0] = thirdSlot;
        slots[1] = firstSlot;
        slots[2] = blankSlot;
        slots[3] = secondSlot;

        address viewer = makeAddr("ViewDataSlotArrayViewer");
        vm.prank(viewer);
        bytes32[] memory returnedData = kernel.viewData(slots);

        assertEq(returnedData.length, slots.length);
        assertEq(returnedData[0], thirdValue);
        assertEq(returnedData[1], firstValue);
        assertEq(returnedData[2], bytes32(0));
        assertEq(returnedData[3], secondValue);
    }

    function testViewDataSlotArrayReturnsDuplicateSlotsInOrder() public {
        bytes32 firstSlot = keccak256("first duplicate view slot");
        bytes32 secondSlot = keccak256("second duplicate view slot");
        bytes32 blankSlot = keccak256("blank duplicate view slot");

        bytes32 firstValue = keccak256("first duplicate view value");
        bytes32 secondValue = keccak256("second duplicate view value");

        IKernel.KernelCall[] memory calls = new IKernel.KernelCall[](2);
        calls[0] = IKernel.KernelCall({slot: firstSlot, data: firstValue});
        calls[1] = IKernel.KernelCall({slot: secondSlot, data: secondValue});

        vm.prank(controller);
        kernel.updateState(calls);

        bytes32[] memory slots = new bytes32[](5);
        slots[0] = secondSlot;
        slots[1] = firstSlot;
        slots[2] = secondSlot;
        slots[3] = blankSlot;
        slots[4] = firstSlot;

        bytes32[] memory returnedData = kernel.viewData(slots);

        assertEq(returnedData.length, slots.length);
        assertEq(returnedData[0], secondValue);
        assertEq(returnedData[1], firstValue);
        assertEq(returnedData[2], secondValue);
        assertEq(returnedData[3], bytes32(0));
        assertEq(returnedData[4], firstValue);
    }

    function testEmptyReadsReturnEmptyData() public view {
        bytes32 startSlot = keccak256("empty read start slot");
        bytes32[] memory slots = new bytes32[](0);

        bytes memory contiguousData = kernel.viewData(startSlot, 0);
        bytes32[] memory arbitraryData = kernel.viewData(slots);

        assertEq(contiguousData.length, 0);
        assertEq(arbitraryData.length, 0);
    }
}
