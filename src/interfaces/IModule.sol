///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IControllerAdapter} from "./IControllerAdapter.sol";
import {Keycode} from "../Utils.sol";

interface IModule is IControllerAdapter {
    error Module__PolicyNotPermitted(address policy);

    function KEYCODE() external pure returns (Keycode);
    function VERSION() external pure returns (uint8 major, uint8 minor);
    function INIT() external;
}
