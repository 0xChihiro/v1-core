///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CREATE3} from "../libraries/CREATE3.sol";
import {IControllerFactory} from "../interfaces/IControllerFactory.sol";

interface IKernelDeploymentView {
    function CONTROLLER() external view returns (address);
    function VAULT() external view returns (address);
}

interface IVaultDeploymentView {
    function CONTROLLER() external view returns (address);
    function KERNEL() external view returns (address);
}

interface ITokenDeploymentView {
    function CONTROLLER() external view returns (address);
}

interface IControllerDeploymentView {
    function KERNEL() external view returns (address);
    function VAULT() external view returns (address);
    function TOKEN() external view returns (address);
    function PROTOCOL_COLLECTOR() external view returns (address);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function MINT_PERMISSION_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract ControllerFactory is IControllerFactory {
    bytes32 private constant CONTROLLER_LABEL = keccak256("CONTROLLER");
    bytes32 private constant KERNEL_LABEL = keccak256("KERNEL");
    bytes32 private constant VAULT_LABEL = keccak256("VAULT");
    bytes32 private constant TOKEN_LABEL = keccak256("TOKEN");

    bytes32 private constant CONTROLLER_CREATION_CODE_HASH =
        0x86890a5113a9d0cc74f1552d95c3b52e6ee8d090cc74eebbcb2b6c6b253c4976;
    bytes32 private constant KERNEL_CREATION_CODE_HASH =
        0xa11ecc8b75b8d1e8da7fbe8a1a6df3acdc00f3748825b0e0596a4e6e8aad7d22;
    bytes32 private constant VAULT_CREATION_CODE_HASH =
        0x9a3d4223c800528457837227eee92086add42d766b227f50fe3414749ee9f347;
    bytes32 private constant TOKEN_CREATION_CODE_HASH =
        0x4f8e32967869952c2219ee457464c67ffff6fd3396ab3c1d536d663b802b7fa6;

    address public immutable PROTOCOL_COLLECTOR;
    address public immutable CONTROLLER_CODE_STORE;
    address public immutable KERNEL_CODE_STORE;
    address public immutable VAULT_CODE_STORE;
    address public immutable TOKEN_CODE_STORE;

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

        PROTOCOL_COLLECTOR = protocolCollector;
        CONTROLLER_CODE_STORE = codeStores.controller;
        KERNEL_CODE_STORE = codeStores.kernel;
        VAULT_CODE_STORE = codeStores.vault;
        TOKEN_CODE_STORE = codeStores.token;
    }

    function launchController(address admin, bytes32 salt, LaunchConfig calldata config)
        external
        returns (Deployment memory deployment)
    {
        if (admin == address(0)) revert ControllerFactory__ZeroAddress();

        address deployer = msg.sender;
        deployment = predictDeployment(deployer, salt);

        _deploy(deployer, salt, KERNEL_LABEL, _kernelCode(deployment), deployment.kernel);
        _deploy(deployer, salt, VAULT_LABEL, _vaultCode(deployment), deployment.vault);
        _deploy(deployer, salt, TOKEN_LABEL, _tokenCode(deployment, config), deployment.token);
        _deploy(deployer, salt, CONTROLLER_LABEL, _controllerCode(deployment, admin), deployment.controller);

        _validateDeployment(deployment, admin);

        controllers.push(deployment.controller);
        controllersByIndex[totalControllers] = deployment.controller;
        deploymentForController[deployment.controller] = deployment;
        unchecked {
            totalControllers++;
        }

        emit Enten__ControllerCreated(
            deployer, admin, salt, deployment.controller, deployment.vault, deployment.kernel, deployment.token
        );
    }

    function predictDeployment(address deployer, bytes32 salt) public view returns (Deployment memory deployment) {
        deployment.controller = CREATE3.getDeployed(_salt(deployer, salt, CONTROLLER_LABEL));
        deployment.kernel = CREATE3.getDeployed(_salt(deployer, salt, KERNEL_LABEL));
        deployment.vault = CREATE3.getDeployed(_salt(deployer, salt, VAULT_LABEL));
        deployment.token = CREATE3.getDeployed(_salt(deployer, salt, TOKEN_LABEL));
    }

    function _validateDeployment(Deployment memory deployment, address admin) internal view {
        if (IControllerDeploymentView(deployment.controller).KERNEL() != deployment.kernel) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IControllerDeploymentView(deployment.controller).VAULT() != deployment.vault) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IControllerDeploymentView(deployment.controller).TOKEN() != deployment.token) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IControllerDeploymentView(deployment.controller).PROTOCOL_COLLECTOR() != PROTOCOL_COLLECTOR) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (!IControllerDeploymentView(deployment.controller).hasRole(bytes32(0), admin)) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (!IControllerDeploymentView(deployment.controller)
                .hasRole(IControllerDeploymentView(deployment.controller).EXECUTOR_ROLE(), admin)) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (!IControllerDeploymentView(deployment.controller)
                .hasRole(IControllerDeploymentView(deployment.controller).MINT_PERMISSION_ROLE(), admin)) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IKernelDeploymentView(deployment.kernel).CONTROLLER() != deployment.controller) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IKernelDeploymentView(deployment.kernel).VAULT() != deployment.vault) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IVaultDeploymentView(deployment.vault).CONTROLLER() != deployment.controller) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (IVaultDeploymentView(deployment.vault).KERNEL() != deployment.kernel) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (ITokenDeploymentView(deployment.token).CONTROLLER() != deployment.controller) {
            revert ControllerFactory__InvalidDeployment();
        }
    }

    function _deploy(address deployer, bytes32 salt, bytes32 label, bytes memory creationCode, address expected)
        internal
    {
        if (CREATE3.deploy(_salt(deployer, salt, label), creationCode) != expected) {
            revert ControllerFactory__InvalidDeployment();
        }
    }

    function _controllerCode(Deployment memory deployment, address admin) internal view returns (bytes memory) {
        return abi.encodePacked(
            CONTROLLER_CODE_STORE.code,
            abi.encode(admin, PROTOCOL_COLLECTOR, deployment.kernel, deployment.vault, deployment.token)
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
                config.preMineAddress,
                config.preMineAmount,
                config.maxSupply
            )
        );
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
