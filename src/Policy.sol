///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ControllerAdapter} from "./ControllerAdapter.sol";
import {Keycode, Permissions} from "./Utils.sol";

abstract contract Policy is ControllerAdapter {
    error Policy__ModuleDoesNotExist(Keycode keycode_);
    error Policy__WrongModuleVersion(bytes expected_);

    constructor(address controller) ControllerAdapter(controller) {}

    /// @notice 5 byte identifier for a policy.
    function KEYCODE() public pure virtual returns (Keycode) {}

    /// @notice Easily accessible indicator for if a policy is activated or not.
    function isActive() external view returns (bool) {
        return CONTROLLER.isPolicyActive(address(this));
    }

    /// @notice Function to grab module address from a given keycode.
    function getModuleAddress(Keycode keycode_) internal view returns (address) {
        address moduleForKeycode = CONTROLLER.getModuleForKeycode(keycode_);
        if (moduleForKeycode == address(0)) revert Policy__ModuleDoesNotExist(keycode_);
        return moduleForKeycode;
    }

    /// @notice Define module dependencies for this policy.
    /// @return dependencies - Keycode array of module dependencies.
    function configureDependencies() external virtual returns (Keycode[] memory dependencies) {}

    /// @notice Function called by kernel to set module function permissions.
    /// @return requests - Array of keycodes and function selectors for requested permissions.
    function requestPermissions() external view virtual returns (Permissions[] memory requests) {}
}
