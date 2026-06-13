///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CREATE3} from "../libraries/CREATE3.sol";
import {IController} from "../interfaces/IController.sol";
import {IControllerFactory} from "../interfaces/IControllerFactory.sol";
import {IDefaultAdminRole} from "../interfaces/IDefaultAdminRole.sol";
import {IKernel} from "../interfaces/IKernel.sol";
import {IToken} from "../interfaces/IToken.sol";
import {IVault} from "../interfaces/IVault.sol";
import {TeamLocker} from "../TeamLocker.sol";
import {Slots} from "../libraries/Slots.sol";

contract ControllerFactory is IControllerFactory {
    bytes32 private constant CONTROLLER_LABEL = keccak256("CONTROLLER");
    bytes32 private constant KERNEL_LABEL = keccak256("KERNEL");
    bytes32 private constant VAULT_LABEL = keccak256("VAULT");
    bytes32 private constant TOKEN_LABEL = keccak256("TOKEN");
    bytes32 private constant TEAM_LOCKER_LABEL = keccak256("TEAM_LOCKER");

    bytes32 private constant CONTROLLER_CREATION_CODE_HASH =
        0xa872d46eb8695510d11b4ce7e4cb43f27ffda7a7ca52575aea8c05e2aec51410;
    bytes32 private constant KERNEL_CREATION_CODE_HASH =
        0xd1fac095a5bf7dd6bdc2a2dabdaa1b960207a13a1ea1aecfb1a03afb5f26aa2d;
    bytes32 private constant VAULT_CREATION_CODE_HASH =
        0x8162cc004878ed2b9ffb65516083fe397f9ea093a7d520f01eeaf72c2081611d;
    bytes32 private constant TOKEN_CREATION_CODE_HASH =
        0xc57994eb8387790d3f3d08829fe368a339cbd16bb76f780bfef4c3e675304a96;
    bytes32 private constant TEAM_LOCKER_CREATION_CODE_HASH =
        0x53a90eb486deaad5df33bd2b87b4638b280747c17e848d58fd2f9bbeec03375a;

    address public immutable PROTOCOL_COLLECTOR;
    address public immutable CONTROLLER_CODE_STORE;
    address public immutable KERNEL_CODE_STORE;
    address public immutable VAULT_CODE_STORE;
    address public immutable TOKEN_CODE_STORE;
    address public immutable TEAM_LOCKER_CODE_STORE;

    address[] public controllers;
    mapping(uint256 => address) public controllersByIndex;
    mapping(address controller => Deployment deployment) public deploymentForController;
    uint256 public totalControllers;

    constructor(address protocolCollector, CreationCodeStores memory codeStores) {
        if (protocolCollector == address(0)) revert ControllerFactory__ZeroAddress();

        _validateCreationCodeStore(codeStores.controller, CONTROLLER_CREATION_CODE_HASH);
        _validateCreationCodeStore(codeStores.kernel, KERNEL_CREATION_CODE_HASH);
        _validateCreationCodeStore(codeStores.vault, VAULT_CREATION_CODE_HASH);
        _validateCreationCodeStore(codeStores.token, TOKEN_CREATION_CODE_HASH);
        _validateCreationCodeStore(codeStores.teamLocker, TEAM_LOCKER_CREATION_CODE_HASH);

        PROTOCOL_COLLECTOR = protocolCollector;
        CONTROLLER_CODE_STORE = codeStores.controller;
        KERNEL_CODE_STORE = codeStores.kernel;
        VAULT_CODE_STORE = codeStores.vault;
        TOKEN_CODE_STORE = codeStores.token;
        TEAM_LOCKER_CODE_STORE = codeStores.teamLocker;
    }

    function launchController(address admin, bytes32 salt, LaunchConfig calldata config)
        external
        returns (Deployment memory deployment)
    {
        if (admin == address(0)) revert ControllerFactory__ZeroAddress();

        address deployer = msg.sender;
        deployment = predictDeployment(deployer, salt);
        _validateLaunchConfig(deployment, config);

        _deploy(deployer, salt, KERNEL_LABEL, _kernelCode(deployment), deployment.kernel);
        _deploy(deployer, salt, VAULT_LABEL, _vaultCode(deployment), deployment.vault);
        _deploy(deployer, salt, TOKEN_LABEL, _tokenCode(deployment, config), deployment.token);
        if (config.teamTokenAmount != 0) {
            _deploy(
                deployer,
                salt,
                TEAM_LOCKER_LABEL,
                _teamLockerCode(deployment, admin, config.teamTokenAmount),
                deployment.teamLocker
            );
        }
        _distributePreMine(deployment, config);
        _deploy(deployer, salt, CONTROLLER_LABEL, _controllerCode(deployment, admin, config), deployment.controller);

        _validateDeployment(deployment, admin, config);

        controllers.push(deployment.controller);
        controllersByIndex[totalControllers] = deployment.controller;
        deploymentForController[deployment.controller] = deployment;
        unchecked {
            totalControllers++;
        }

        emit Enten__ControllerCreated(
            deployer,
            admin,
            salt,
            deployment.controller,
            deployment.vault,
            deployment.kernel,
            deployment.token,
            deployment.teamLocker
        );
    }

    function predictDeployment(address deployer, bytes32 salt) public view returns (Deployment memory deployment) {
        deployment.controller = CREATE3.getDeployed(_salt(deployer, salt, CONTROLLER_LABEL));
        deployment.kernel = CREATE3.getDeployed(_salt(deployer, salt, KERNEL_LABEL));
        deployment.vault = CREATE3.getDeployed(_salt(deployer, salt, VAULT_LABEL));
        deployment.token = CREATE3.getDeployed(_salt(deployer, salt, TOKEN_LABEL));
        deployment.teamLocker = CREATE3.getDeployed(_salt(deployer, salt, TEAM_LOCKER_LABEL));
    }

    function _validateDeployment(Deployment memory deployment, address admin, LaunchConfig calldata config)
        internal
        view
    {
        IController controller = IController(deployment.controller);
        if (address(controller.KERNEL()) != deployment.kernel) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (address(controller.VAULT()) != deployment.vault) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (address(controller.TOKEN()) != deployment.token) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (controller.PROTOCOL_COLLECTOR() != PROTOCOL_COLLECTOR) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (!controller.hasRole(IDefaultAdminRole(deployment.controller).DEFAULT_ADMIN_ROLE(), admin)) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (!controller.hasRole(controller.EXECUTOR_ROLE(), admin)) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (!controller.hasRole(controller.MINT_PERMISSION_ROLE(), admin)) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IKernel(deployment.kernel).CONTROLLER() != deployment.controller) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IKernel(deployment.kernel).VAULT() != deployment.vault) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IVault(deployment.vault).CONTROLLER() != deployment.controller) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (address(IVault(deployment.vault).KERNEL()) != deployment.kernel) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IToken(deployment.token).CONTROLLER() != deployment.controller) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (uint256(IKernel(deployment.kernel).viewData(Slots.TEAM_LOCKED_TOKENS_SLOT)) != config.teamTokenAmount) {
            revert ControllerFactory__InvalidDeployment();
        }

        IToken token = IToken(deployment.token);
        uint256 nonTeamAmount = config.preMineAmount - config.teamTokenAmount;
        if (nonTeamAmount != 0 && token.balanceOf(config.preMineAddress) != nonTeamAmount) {
            revert ControllerFactory__InvalidDeployment();
        }

        if (config.teamTokenAmount != 0) {
            TeamLocker locker = TeamLocker(deployment.teamLocker);
            if (locker.STARTING_LOCKED() != config.teamTokenAmount) {
                revert ControllerFactory__InvalidDeployment();
            }
            if (locker.TOKEN() != deployment.token) {
                revert ControllerFactory__InvalidDeployment();
            }
            if (address(locker.KERNEL()) != deployment.kernel) {
                revert ControllerFactory__InvalidDeployment();
            }
            if (!locker.hasRole(locker.DEFAULT_ADMIN_ROLE(), admin)) {
                revert ControllerFactory__InvalidDeployment();
            }
            if (!locker.hasRole(locker.CLAIMER_ROLE(), admin)) {
                revert ControllerFactory__InvalidDeployment();
            }
            if (token.balanceOf(deployment.teamLocker) != config.teamTokenAmount) {
                revert ControllerFactory__InvalidDeployment();
            }
        }
    }

    function _deploy(address deployer, bytes32 salt, bytes32 label, bytes memory creationCode, address expected)
        internal
    {
        if (CREATE3.deploy(_salt(deployer, salt, label), creationCode) != expected) {
            revert ControllerFactory__InvalidDeployment();
        }
    }

    function _controllerCode(Deployment memory deployment, address admin, LaunchConfig calldata config)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            CONTROLLER_CODE_STORE.code,
            abi.encode(
                admin, PROTOCOL_COLLECTOR, deployment.kernel, deployment.vault, deployment.token, config.teamTokenAmount
            )
        );
    }

    function _kernelCode(Deployment memory deployment) internal view returns (bytes memory) {
        return abi.encodePacked(KERNEL_CODE_STORE.code, abi.encode(deployment.controller, deployment.vault));
    }

    function _vaultCode(Deployment memory deployment) internal view returns (bytes memory) {
        return abi.encodePacked(VAULT_CODE_STORE.code, abi.encode(deployment.controller, deployment.kernel));
    }

    function _tokenCode(Deployment memory deployment, LaunchConfig calldata config)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            TOKEN_CODE_STORE.code,
            abi.encode(
                config.tokenName,
                config.tokenSymbol,
                deployment.controller,
                config.preMineAmount == 0 ? address(0) : address(this),
                config.preMineAmount,
                config.maxSupply
            )
        );
    }

    function _teamLockerCode(Deployment memory deployment, address admin, uint256 teamTokenAmount)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            TEAM_LOCKER_CODE_STORE.code, abi.encode(teamTokenAmount, admin, deployment.token, deployment.kernel)
        );
    }

    function _validateLaunchConfig(Deployment memory deployment, LaunchConfig calldata config) internal pure {
        if (config.teamTokenAmount > config.preMineAmount) revert ControllerFactory__InvalidLaunchConfig();

        uint256 nonTeamAmount = config.preMineAmount - config.teamTokenAmount;
        if (nonTeamAmount != 0 && config.preMineAddress == address(0)) {
            revert ControllerFactory__ZeroAddress();
        }
        if (config.teamTokenAmount != 0 && nonTeamAmount != 0 && config.preMineAddress == deployment.teamLocker) {
            revert ControllerFactory__InvalidLaunchConfig();
        }
    }

    function _distributePreMine(Deployment memory deployment, LaunchConfig calldata config) internal {
        IToken token = IToken(deployment.token);
        uint256 nonTeamAmount = config.preMineAmount - config.teamTokenAmount;

        if (nonTeamAmount != 0) {
            if (!token.transfer(config.preMineAddress, nonTeamAmount)) revert ControllerFactory__InvalidDeployment();
        }
        if (config.teamTokenAmount != 0) {
            if (!token.transfer(deployment.teamLocker, config.teamTokenAmount)) {
                revert ControllerFactory__InvalidDeployment();
            }
        }
    }

    function _validateCreationCodeStore(address codeStore, bytes32 expectedHash) internal view {
        if (codeStore == address(0) || codeStore.codehash != expectedHash) {
            revert ControllerFactory__InvalidCreationCodeStore();
        }
    }

    function _salt(address deployer, bytes32 salt, bytes32 label) internal pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt, label));
    }
}
