///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IKernel {
    struct KernelCall {
        bytes32 slot;
        bytes32 data;
    }
    /// @notice Vault address authorized alongside the controller to call accounting arithmetic functions.
    /// @return The immutable vault address.
    function VAULT() external view returns (address);

    /// @notice Compatibility alias for the vault/accounting writer address.
    /// @return The immutable vault address.
    function accountingWriter() external view returns (address);

    /// @notice Write contiguous 32-byte words starting at a storage slot.
    /// @param startSlot The first storage slot to write.
    /// @param data Packed 32-byte words to write in order.
    /// @dev Callable only by the controller. `data.length` must be a multiple of 32.
    ///      Empty data is a no-op. Writes cannot overflow the slot range.
    function updateState(bytes32 startSlot, bytes calldata data) external;

    /// @notice Write a single 32-byte word to a storage slot.
    /// @param slot The storage slot to write.
    /// @param data The 32-byte word to store.
    /// @dev Callable only by the controller.
    function updateState(bytes32 slot, bytes32 data) external;

    /// @notice Write arbitrary 32-byte words to arbitrary storage slots.
    /// @param calls Slot/data pairs to write.
    /// @dev Callable only by the controller. Calls are applied in order, so duplicate slots use
    ///      last-write-wins semantics. Empty arrays are no-ops.
    function updateState(KernelCall[] calldata calls) external;

    /// @notice Add a value to the numeric value stored in a slot.
    /// @param slot The storage slot to update.
    /// @param value The amount to add.
    /// @dev Callable by the controller or vault. Reverts on overflow. The kernel assumes callers only
    ///      use arithmetic against numeric slots.
    function add(bytes32 slot, bytes32 value) external;

    /// @notice Apply multiple sequential additions.
    /// @param calls Slot/value pairs to add.
    /// @dev Callable by the controller or vault. Calls are applied in order and the whole call reverts
    ///      if any addition overflows.
    function add(KernelCall[] calldata calls) external;

    /// @notice Subtract a value from the numeric value stored in a slot.
    /// @param slot The storage slot to update.
    /// @param value The amount to subtract.
    /// @dev Callable by the controller or vault. Reverts on underflow. The kernel assumes callers only
    ///      use arithmetic against numeric slots.
    function sub(bytes32 slot, bytes32 value) external;

    /// @notice Apply multiple sequential subtractions.
    /// @param calls Slot/value pairs to subtract.
    /// @dev Callable by the controller or vault. Calls are applied in order and the whole call reverts
    ///      if any subtraction underflows.
    function sub(KernelCall[] calldata calls) external;

    /// @notice Read a contiguous range of raw storage slots.
    /// @param startSlot The first storage slot to read.
    /// @param nSlots The number of slots to read.
    /// @return A packed byte array containing each 32-byte slot value in order.
    /// @dev This is a raw read API. Passing zero slots returns empty bytes.
    function viewData(bytes32 startSlot, uint256 nSlots) external view returns (bytes memory);

    /// @notice Read arbitrary raw storage slots.
    /// @param slots Storage slots to read.
    /// @return Stored values in the same order as `slots`.
    /// @dev Duplicate slots return duplicate values in order. Passing an empty array returns an empty array.
    function viewData(bytes32[] calldata slots) external view returns (bytes32[] memory);

    /// @notice Read a single raw storage slot.
    /// @param slot The storage slot to read.
    /// @return The value stored at the given slot.
    function viewData(bytes32 slot) external view returns (bytes32);
}
