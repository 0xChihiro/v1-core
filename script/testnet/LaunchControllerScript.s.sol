///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";

import {IControllerFactory} from "../../src/interfaces/IControllerFactory.sol";
import {ControllerFactory} from "../../src/factories/ControllerFactory.sol";
import {console} from "forge-std/console.sol";

contract LaunchControllerScript is Script {
    address protocolCollector = 0xD9172fE47C9E4e2CbD2941853a83F964f7B0f47B;
    ControllerFactory controllerFactory = ControllerFactory(0xf9D61D026D7B2726C7B88407a447719e0eb43DCC);

    function run() public {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        /// Replace with your own admin
        address admin = 0x9C47F4f17Aa5B0e66193333Fd60d5E7DDf9322db;

        /// Replace with whatever configurations you need
        IControllerFactory.LaunchConfig memory config = IControllerFactory.LaunchConfig({
            tokenName: "Enten",
            tokenSymbol: "ENTEN",
            preMineAddress: admin,
            preMineAmount: 3_000_000e18,
            teamTokenAmount: 0,
            maxSupply: 10_000_000e18
        });

        /// Replace with your own psuedorandom value
        bytes32 salt = keccak256("enten.testnet.launch.v.1");

        IControllerFactory.Deployment memory deployments = controllerFactory.launchController(admin, salt, config);
        vm.stopBroadcast();

        console.log("Controller:", deployments.controller);
        console.log("Kernel:", deployments.kernel);
        console.log("Vault:", deployments.vault);
        console.log("Token:", deployments.token);
        console.log("TeamLocker:", deployments.teamLocker);
    }
}
