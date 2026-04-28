///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IKernel {
    struct KernelCall {
        bytes32 slot;
        bytes32 data;
    }
    /// @notice Address which can call functions like add and sub.
    /// @return the address that is currently stored as the Accounting Writer
    /// @dev Should be set to the Vault Contract 
    function accountingWriter() external view returns (address);
    /// @notice Set the accounting writer
    /// @param The account you wish to set
    function setAccountingWriter(address) external;
    /// @notice update slot(s) with generic data
    /// @param the slot you wish to write to
    /// @param the data that starts at the given slot
    /// @dev The data is written in order starting at the given slot is 32 bytes words
    function updateState(bytes32, bytes calldata) external;
    /// @notice update a single slot with a single 32 byte word
    /// @param the slot you want to write
    /// @param the data you want to write
    function updateState(bytes32, bytes32) external;
    /// @notice write an array of arbitray slots with arbitrary data
    /// @param array of structs containing a single struct with a single 32 byte word of data.
    function updateState(KernelCall[] calldata) external;
    /// @notice update a slot by adding the given value to it
    /// @param the slot to update
    /// @param the value to add to the slot
    /// @dev none of the add or sub functions overwrite values
    function add(bytes32, bytes32) external;
    /// @notice perform multiple adds in one call
    /// @param array of structs containing one slot and one 32 byte word of data.
    function add(KernelCall[] calldata) external;
    /// @notice subtract from a given slot
    /// @param the slot to subtract from its value
    /// @param the amount to subtract from the stored value
    function sub(bytes32, bytes32) external;
    /// @notice perform a batch of subtract calls
    /// @param array of slot and value pairings to subtract from the slots stored data
    function sub(KernelCall[] calldata) external;
    /// @notice view the value of contingious bit of storage
    /// @param the value of the starting slot
    /// @param the number of slots to read.
    /// @return A continious slice of data from the slots give
    function viewData(bytes32, uint256) external view returns (bytes memory);
    /// @notice view a series of slots that do not have to be contingious
    /// @param array of slot values to read
    /// @return array of stored values
    function viewData(bytes32[] calldata) external view returns (bytes32[] memory);
    /// @notice view a single store slot
    /// @param the slot to view
    /// @return the value stored at the given slot
    function viewData(bytes32) external view returns (bytes32);
}
