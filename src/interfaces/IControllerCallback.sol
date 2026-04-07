///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IControllerCallback {
    struct CallbackValue {
        address asset;
        uint256 value;
    }

    function finalizeBuy(CallbackValue[] memory, address) external returns (bool);
}

