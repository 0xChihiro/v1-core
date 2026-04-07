///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IBorrower {
    struct Position {
        uint256 collateral;
        mapping(address => uint256) borrowed;
    }

    struct BorrowCall {
        address asset;
        uint256 amount;
    }

    struct RepayCall {
        address asset;
        uint256 amount;
    }
    function addBorrowableAsset(address) external;
    function totalBorrows(address) external view returns (uint256);
}
