///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IControllerAdapter} from "./IControllerAdapter.sol";
import {Keycode, Permissions} from "../Utils.sol";

interface IPolicy is IControllerAdapter {
    error Policy__ModuleDoesNotExist(Keycode keycode);
    error Policy__WrongModuleVersion(bytes expected);

    function KEYCODE() external pure returns (Keycode);
    function isActive() external view returns (bool);
    function configureDependencies() external returns (Keycode[] memory dependencies);
    function requestPermissions() external view returns (Permissions[] memory requests);
}
