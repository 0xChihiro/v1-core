///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ControllerFactory} from "../src/factories/ControllerFactory.sol";
import {Controller} from "../src/Controller.sol";
import {Kernel} from "../src/Kernel.sol";
import {Vault} from "../src/Vault.sol";
import {EntenToken} from "../src/EntenToken.sol";

contract LaunchScript is Script {
    bytes constant controllerCode = type(Controller).creationCode;
    bytes constant tokenCode = type(EntenToken).creationCode;
    bytes constant vaultCode = type(Vault).creationCode;
    bytes constant kernelCode = type(Kernel).creationCode;

    /// Not the actual controller factory address. Will be replaced once the factory is live.
    // ControllerFactory constant factory = ControllerFactory(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    /// Change admin address to the address you want the admin address to be.
    address admin = address(1);

    function run() public {
        vm.startBroadcast();
        ControllerFactory factory = new ControllerFactory(address(42));

        bytes32 salt = keccak256("enten.controller.launch");
        ControllerFactory.Deployment memory predicted = factory.predictDeployment(msg.sender, salt);

        /// Change The necessary constructor inputs to what you need them to be.
        ControllerFactory.CreationCode memory creationCode = ControllerFactory.CreationCode({
            controller: abi.encodePacked(
                controllerCode,
                abi.encode(admin, factory.PROTOCOL_COLLECTOR(), predicted.kernel, predicted.vault, predicted.token)
            ),
            kernel: abi.encodePacked(kernelCode, abi.encode(predicted.controller, predicted.vault)),
            vault: abi.encodePacked(vaultCode, abi.encode(predicted.controller, predicted.kernel)),
            /// Update to your specific token data.
            token: abi.encodePacked(
                tokenCode, abi.encode("Enten", "ENTEN", predicted.controller, address(0), 0, 10_000_000e18)
            )
        });

        /// Controller Factory Validates deployments to ensure things were done properly.
        ControllerFactory.Deployment memory deployments = factory.launchController(admin, salt, creationCode);

        vm.stopBroadcast();

        console.log(deployments.controller);
        console.log(deployments.kernel);
        console.log(deployments.vault);
        console.log(deployments.token);
    }
}
