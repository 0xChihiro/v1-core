///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Controller} from "../src/Controller.sol";
import {ControllerFactory} from "../src/factories/ControllerFactory.sol";
import {CreationCodeStore} from "../src/factories/CreationCodeStore.sol";
import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {Kernel} from "../src/Kernel.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";

contract LaunchScript is Script {
    /// Not the actual controller factory address. Will be replaced once the factory is live.
    // ControllerFactory constant factory = ControllerFactory(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    /// Change admin address to the address you want the admin address to be.
    address admin = address(1);

    function run() public {
        vm.startBroadcast();
        IControllerFactory.CreationCodeStores memory codeStores = IControllerFactory.CreationCodeStores({
            controller: address(new CreationCodeStore(type(Controller).creationCode)),
            kernel: address(new CreationCodeStore(type(Kernel).creationCode)),
            vault: address(new CreationCodeStore(type(Vault).creationCode)),
            token: address(new CreationCodeStore(type(Token).creationCode))
        });

        ControllerFactory factory = new ControllerFactory(address(42), codeStores);

        bytes32 salt = keccak256("enten.controller.launch");

        /// Change The necessary constructor inputs to what you need them to be.
        IControllerFactory.LaunchConfig memory config = IControllerFactory.LaunchConfig({
            tokenName: "Enten",
            tokenSymbol: "ENTEN",
            preMineAddress: address(0),
            preMineAmount: 0,
            maxSupply: 10_000_000e18
        });

        /// Controller Factory Validates deployments to ensure things were done properly.
        IControllerFactory.Deployment memory deployments = factory.launchController(admin, salt, config);

        vm.stopBroadcast();

        console.log(deployments.controller);
        console.log(deployments.kernel);
        console.log(deployments.vault);
        console.log(deployments.token);
    }
}
