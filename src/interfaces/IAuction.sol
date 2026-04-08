///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IAuction {
    function bid(uint256 amount, uint256 deadline, uint256 epochId, address buyer) external returns (uint256);
    function isLive() external view returns (bool);
    function start() external;
    function LOT_SIZE() external view returns (uint256);
}

