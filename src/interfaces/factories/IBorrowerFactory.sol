///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IBorrowerFactory {
    struct BorrowerConfig {
        address controller;
        address token;
    }

    function createBorrower(BorrowerConfig memory) external returns (address);
}
