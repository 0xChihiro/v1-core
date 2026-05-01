///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Controller} from "../src/Controller.sol";
import {EntenToken} from "../src/EntenToken.sol";
import {Kernel} from "../src/Kernel.sol";
import {Vault} from "../src/Vault.sol";
import {ControllerFactory} from "../src/factories/ControllerFactory.sol";
import {Test} from "forge-std/Test.sol";

contract ControllerFactoryTest is Test {
    function testLaunchControllerWithCreate3ImmutableDeployment() public {
        address protocolCollector = makeAddr("Protocol Collector");
        address admin = makeAddr("Admin");
        address deployer = makeAddr("Deployer");
        bytes32 salt = keccak256("first enten deployment");

        ControllerFactory factory = new ControllerFactory(protocolCollector);
        ControllerFactory.Deployment memory predicted = factory.predictDeployment(deployer, salt);

        ControllerFactory.CreationCode memory creationCode = ControllerFactory.CreationCode({
            controller: abi.encodePacked(
                type(Controller).creationCode,
                abi.encode(admin, protocolCollector, predicted.kernel, predicted.vault, predicted.token)
            ),
            kernel: abi.encodePacked(type(Kernel).creationCode, abi.encode(predicted.controller, predicted.vault)),
            vault: abi.encodePacked(type(Vault).creationCode, abi.encode(predicted.controller, predicted.kernel)),
            token: abi.encodePacked(
                type(EntenToken).creationCode,
                abi.encode("Enten", "ENTEN", predicted.controller, address(0), 0, type(uint256).max)
            )
        });

        vm.prank(deployer);
        ControllerFactory.Deployment memory deployed = factory.launchController(admin, salt, creationCode);

        assertEq(deployed.controller, predicted.controller);
        assertEq(deployed.kernel, predicted.kernel);
        assertEq(deployed.vault, predicted.vault);
        assertEq(deployed.token, predicted.token);

        Controller controller = Controller(deployed.controller);
        Kernel kernel = Kernel(deployed.kernel);
        Vault vault = Vault(deployed.vault);
        EntenToken token = EntenToken(deployed.token);

        assertEq(address(controller.KERNEL()), deployed.kernel);
        assertEq(address(controller.VAULT()), deployed.vault);
        assertEq(address(controller.TOKEN()), deployed.token);
        assertEq(controller.PROTOCOL_COLLECTOR(), protocolCollector);
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(controller.hasRole(controller.EXECUTOR_ROLE(), admin));
        assertTrue(controller.hasRole(controller.MINT_PERMISSION_ROLE(), admin));

        assertEq(kernel.CONTROLLER(), deployed.controller);
        assertEq(kernel.VAULT(), deployed.vault);
        assertEq(kernel.accountingWriter(), deployed.vault);
        assertEq(vault.CONTROLLER(), deployed.controller);
        assertEq(address(vault.KERNEL()), deployed.kernel);
        assertEq(token.CONTROLLER(), deployed.controller);
    }
}
