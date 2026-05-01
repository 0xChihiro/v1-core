///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ControllerAdapter} from "./ControllerAdapter.sol";
import {Keycode} from "./Utils.sol";

abstract contract Module is ControllerAdapter {
    error Module__PolicyNotPermitted(address policy);
    modifier permissioned() {
        if (msg.sender == address(CONTROLLER) || !CONTROLLER.modulePermissions(KEYCODE(), msg.sender, msg.sig)) {
            revert Module__PolicyNotPermitted(msg.sender);
        }
        _;
    }

    constructor(address controller) ControllerAdapter(controller) {}

    /// @notice 5 byte identifier for a module.
    function KEYCODE() public pure virtual returns (Keycode) {}

    /// @notice Returns which semantic version of a module is being implemented.
    /// @return major - Major version upgrade indicates breaking change to the interface.
    /// @return minor - Minor version change retains backward-compatible interface.
    function VERSION() external pure virtual returns (uint8 major, uint8 minor) {}

    /// @notice Initialization function for the module
    /// @dev    This function is called when the module is installed or upgraded by the kernel.
    /// @dev    MUST BE GATED BY onlyKernel. Used to encompass any initialization or upgrade logic.
    function INIT() external virtual onlyController {}
}
