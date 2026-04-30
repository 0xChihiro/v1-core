///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CREATE3} from "../libraries/CREATE3.sol";

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
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract ControllerFactory {
    bytes32 private constant CONTROLLER_LABEL = keccak256("CONTROLLER");
    bytes32 private constant KERNEL_LABEL = keccak256("KERNEL");
    bytes32 private constant VAULT_LABEL = keccak256("VAULT");
    bytes32 private constant TOKEN_LABEL = keccak256("TOKEN");

    address public immutable PROTOCOL_COLLECTOR;

    address[] public controllers;
    mapping(uint256 => address) public controllersByIndex;
    mapping(address controller => Deployment deployment) public deploymentForController;
    uint256 public totalControllers;

    struct Deployment {
        address controller;
        address kernel;
        address vault;
        address token;
    }

    struct CreationCode {
        bytes controller;
        bytes kernel;
        bytes vault;
        bytes token;
    }

    event Enten__ControllerCreated(
        address indexed deployer,
        address indexed admin,
        bytes32 indexed salt,
        address controller,
        address vault,
        address kernel,
        address token
    );

    error ControllerFactory__ZeroAddress();
    error ControllerFactory__InvalidDeployment();

    constructor(address protocolCollector) {
        if (protocolCollector == address(0)) revert ControllerFactory__ZeroAddress();
        PROTOCOL_COLLECTOR = protocolCollector;
    }

    function launchController(address admin, bytes32 salt, CreationCode calldata creationCode)
        external
        returns (Deployment memory deployment)
    {
        if (admin == address(0)) revert ControllerFactory__ZeroAddress();

        address deployer = msg.sender;
        deployment = predictDeployment(deployer, salt);

        if (CREATE3.deploy(_salt(deployer, salt, KERNEL_LABEL), creationCode.kernel) != deployment.kernel) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (CREATE3.deploy(_salt(deployer, salt, VAULT_LABEL), creationCode.vault) != deployment.vault) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (CREATE3.deploy(_salt(deployer, salt, TOKEN_LABEL), creationCode.token) != deployment.token) {
            revert ControllerFactory__InvalidDeployment();
        }
        if (CREATE3.deploy(_salt(deployer, salt, CONTROLLER_LABEL), creationCode.controller) != deployment.controller) {
            revert ControllerFactory__InvalidDeployment();
        }

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

    function _salt(address deployer, bytes32 salt, bytes32 label) internal pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt, label));
    }
}
