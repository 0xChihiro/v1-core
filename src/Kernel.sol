///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "./interfaces/IController.sol";
import {IKernel} from "./interfaces/IKernel.sol";

contract Kernel is IKernel {
    error Kernel__ControllerZeroAddress();
    error Kernel__InvalidCaller();
    error Kernel__InvalidSlotDataLength();
    error Kernel__SlotReadOverflow();
    error Kernel__AddOverflow();
    error Kernel__SubUnderflow();
    error Kernel__OnlyController();

    address public immutable CONTROLLER;

    constructor(address controller) {
        if (controller == address(0)) revert Kernel__ControllerZeroAddress();
        CONTROLLER = controller;
    }

    function updateState(bytes32 startSlot, bytes calldata data) external {
        if (!IController(CONTROLLER).isPermissioned(msg.sender)) revert Kernel__InvalidCaller();
        if (data.length & 31 != 0) revert Kernel__InvalidSlotDataLength();

        assembly ("memory-safe") {
            let slot := startSlot
            let offset := data.offset
            let end := add(offset, data.length)

            for {} lt(offset, end) {
                offset := add(offset, 0x20)
                slot := add(slot, 1)
            } {
                sstore(slot, calldataload(offset))
            }
        }
    }

    function updateState(bytes32 slot, bytes32 data) external {
        if (!IController(CONTROLLER).isPermissioned(msg.sender)) revert Kernel__InvalidCaller();
        assembly ("memory-safe") {
            sstore(slot, data)
        }
    }

    function updateState(KernelCall[] calldata calls) external {
        if (!IController(CONTROLLER).isPermissioned(msg.sender)) revert Kernel__InvalidCaller();

        assembly ("memory-safe") {
            let calldataptr := calls.offset
            let end := add(calldataptr, shl(6, calls.length))

            for {} lt(calldataptr, end) { calldataptr := add(calldataptr, 0x40) } {
                sstore(calldataload(calldataptr), calldataload(add(calldataptr, 0x20)))
            }
        }
    }

    function add(KernelCall[] calldata calls) external {
        if (!IController(CONTROLLER).isPermissioned(msg.sender)) revert Kernel__InvalidCaller();
        for (uint256 i = 0; i < calls.length;) {
            bytes32 slot = calls[i].slot;
            uint256 data;
            assembly ("memory-safe") {
                data := sload(slot)
            }
            uint256 amount = uint256(calls[i].data);
            unchecked {
                uint256 updated = data + amount;
                if (updated < data) revert Kernel__AddOverflow();
                assembly ("memory-safe") {
                    sstore(slot, updated)
                }
                ++i;
            }
        }
    }

    function add(bytes32 slot, bytes32 value) external {
        if (!IController(CONTROLLER).isPermissioned(msg.sender)) revert Kernel__InvalidCaller();
        uint256 data;
        assembly ("memory-safe") {
            data := sload(slot)
        }
        unchecked {
            uint256 updated = data + uint256(value);
            if (updated < data) revert Kernel__AddOverflow();
            assembly ("memory-safe") {
                sstore(slot, updated)
            }
        }
    }

    function sub(bytes32 slot, bytes32 value) external {
        if (!IController(CONTROLLER).isPermissioned(msg.sender)) revert Kernel__InvalidCaller();
        uint256 data;
        assembly ("memory-safe") {
            data := sload(slot)
        }
        uint256 amount = uint256(value);
        if (amount > data) revert Kernel__SubUnderflow();
        unchecked {
            assembly ("memory-safe") {
                sstore(slot, sub(data, amount))
            }
        }
    }

    function sub(KernelCall[] calldata calls) external {
        if (!IController(CONTROLLER).isPermissioned(msg.sender)) revert Kernel__InvalidCaller();
        for (uint256 i = 0; i < calls.length;) {
            bytes32 slot = calls[i].slot;
            uint256 data;
            assembly ("memory-safe") {
                data := sload(slot)
            }
            uint256 amount = uint256(calls[i].data);
            if (amount > data) revert Kernel__SubUnderflow();
            unchecked {
                assembly ("memory-safe") {
                    sstore(slot, sub(data, amount))
                }
                ++i;
            }
        }
    }

    function viewData(bytes32 startSlot, uint256 nSlots) external view returns (bytes memory data) {
        if (nSlots > type(uint256).max >> 5) revert Kernel__SlotReadOverflow();

        assembly ("memory-safe") {
            let length := shl(5, nSlots)
            data := mload(0x40)
            mstore(data, length)

            let ptr := add(data, 0x20)
            let end := add(ptr, length)
            let slot := startSlot

            for {} lt(ptr, end) {
                ptr := add(ptr, 0x20)
                slot := add(slot, 1)
            } {
                mstore(ptr, sload(slot))
            }

            mstore(0x40, end)
        }
    }

    function viewData(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        assembly ("memory-safe") {
            let memptr := mload(0x40)
            let start := memptr
            // for abi encoding the response - the array will be found at 0x20
            mstore(memptr, 0x20)
            // next we store the length of the return array
            mstore(add(memptr, 0x20), slots.length)
            // update memptr to the first location to hold an array entry
            memptr := add(memptr, 0x40)
            // A left bit-shift of 5 is equivalent to multiplying by 32 but costs less gas.
            let end := add(memptr, shl(5, slots.length))
            let calldataptr := slots.offset
            for {} lt(memptr, end) {
                memptr := add(memptr, 0x20)
                calldataptr := add(calldataptr, 0x20)
            } {
                mstore(memptr, sload(calldataload(calldataptr)))
            }
            return(start, sub(end, start))
        }
    }

    function viewData(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, sload(slot))
            return(0, 0x20)
        }
    }
}
