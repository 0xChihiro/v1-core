///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "./interfaces/IController.sol";

abstract contract ControllerAdapter {
    error ControllerAdapter__OnlyController(address caller);

    IController public immutable CONTROLLER;

    constructor(address controller) {
        CONTROLLER = IController(controller);
    }

    /// @notice Modifier to restrict functions to be called only by kernel.
    modifier onlyController() {
        if (msg.sender != address(CONTROLLER)) revert ControllerAdapter__OnlyController(msg.sender);
        _;
    }
}
