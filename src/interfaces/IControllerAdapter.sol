///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "./IController.sol";

interface IControllerAdapter {
    error ControllerAdapter__OnlyController(address caller);

    function CONTROLLER() external view returns (IController);
}
