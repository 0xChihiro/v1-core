///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IKernel {
    struct KernelCall {
        bytes32 slot;
        bytes32 data;
    }
    function updateState(bytes32, bytes calldata) external;
    function updateState(bytes32, bytes32) external;
    function updateState(KernelCall[] calldata) external;
    function add(bytes32, bytes32) external;
    function add(KernelCall[] calldata) external;
    function sub(bytes32, bytes32) external;
    function sub(KernelCall[] calldata) external;
    function viewData(bytes32, uint256) external view returns (bytes memory);
    function viewData(bytes32[] calldata) external view returns (bytes32[] memory);
    function viewData(bytes32) external view returns (bytes32);
}
