///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ProtocolCollector} from "../../src/ProtocolCollector.sol";
import {ControllerFactory} from "../../src/factories/ControllerFactory.sol";
import {IControllerFactory} from "../../src/interfaces/IControllerFactory.sol";
import {CreationCodeStore} from "../../src/factories/CreationCodeStore.sol";
import {Controller} from "../../src/Controller.sol";
import {Kernel} from "../../src/Kernel.sol";
import {Vault} from "../../src/Vault.sol";
import {Token} from "../../src/Token.sol";

contract LaunchCreationCodeScript is Script {
    function run() public {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
        address collector = address(new ProtocolCollector(0x9C47F4f17Aa5B0e66193333Fd60d5E7DDf9322db));

        address controllerCodeStore = address(new CreationCodeStore(type(Controller).creationCode));
        address kernelCodeStore = address(new CreationCodeStore(type(Kernel).creationCode));
        address vaultCodeStore = address(new CreationCodeStore(type(Vault).creationCode));
        address tokenCodeStore = address(new CreationCodeStore(type(Token).creationCode));

        IControllerFactory.CreationCodeStores memory codeStores = IControllerFactory.CreationCodeStores({
            controller: controllerCodeStore, kernel: kernelCodeStore, vault: vaultCodeStore, token: tokenCodeStore
        });

        address factory = address(new ControllerFactory(collector, codeStores));

        vm.stopBroadcast();

        console.log(collector);
        console.log(factory);
    }
}
