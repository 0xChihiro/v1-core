///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Controller} from "../Controller.sol";

contract ControllerFactory {
    address public immutable PROTOCOL_COLLECTOR;

    address[] public controllers;
    mapping(uint256 => address) public controllersByIndex;
    uint256 public totalControllers;

    event Enten__ControllerCreated(address indexed controller, address indexed vault, address indexed kernel);

    error ControllerFactory__ZeroAddress();

    constructor(address protocolCollector) {
        if (protocolCollector == address(0)) revert ControllerFactory__ZeroAddress();
        PROTOCOL_COLLECTOR = protocolCollector;
    }

    function launchController(address admin) external {
        Controller controller = new Controller(admin, PROTOCOL_COLLECTOR);
        address kernel = address(controller.KERNEL());
        address vault = address(controller.VAULT());

        controllers.push(address(controller));
        controllersByIndex[totalControllers] = address(controller);
        unchecked {
            totalControllers++;
        }

        emit Enten__ControllerCreated(address(controller), vault, kernel);
    }
}
