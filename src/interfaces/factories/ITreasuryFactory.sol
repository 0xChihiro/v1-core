///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface ITreasuryFactory {
    function createTreasury() external returns (address);
}
