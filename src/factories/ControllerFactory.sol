///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Controller} from "../Controller.sol";
import {IControllerFactory} from "../interfaces/factories/IControllerFactory.sol";

contract ControllerFactory is IControllerFactory {
    function createController(ControllerConfig memory config) external returns (address) {
        return address(new Controller(config));
    }
}
