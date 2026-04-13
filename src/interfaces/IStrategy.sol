///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IStrategy {
    function asset() external view returns (address);
    function execute(bytes calldata) external returns (bool);
    function activeFunds() external view returns (uint256);
}
