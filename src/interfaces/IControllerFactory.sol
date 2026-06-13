///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IControllerFactory {
    struct Deployment {
        address controller;
        address kernel;
        address vault;
        address token;
        address teamLocker;
    }

    struct LaunchConfig {
        string tokenName;
        string tokenSymbol;
        address preMineAddress;
        uint256 preMineAmount;
        uint256 teamTokenAmount;
        uint256 maxSupply;
    }

    struct CreationCodeStores {
        address controller;
        address kernel;
        address vault;
        address token;
        address teamLocker;
    }

    event Enten__ControllerCreated(
        address indexed deployer,
        address indexed admin,
        bytes32 indexed salt,
        address controller,
        address vault,
        address kernel,
        address token,
        address teamLocker
    );

    error ControllerFactory__ZeroAddress();
    error ControllerFactory__InvalidLaunchConfig();
    error ControllerFactory__InvalidDeployment();
    error ControllerFactory__InvalidCreationCodeStore();
    error CREATE3__EmptyCreationCode();
    error CREATE3__DeploymentFailed();
    error CREATE3__ProxyDeploymentFailed();

    function PROTOCOL_COLLECTOR() external view returns (address);
    function CONTROLLER_CODE_STORE() external view returns (address);
    function KERNEL_CODE_STORE() external view returns (address);
    function VAULT_CODE_STORE() external view returns (address);
    function TOKEN_CODE_STORE() external view returns (address);
    function TEAM_LOCKER_CODE_STORE() external view returns (address);

    function controllers(uint256 index) external view returns (address);
    function controllersByIndex(uint256 index) external view returns (address);
    function deploymentForController(address controller)
        external
        view
        returns (address controller_, address kernel, address vault, address token, address teamLocker);
    function totalControllers() external view returns (uint256);

    function launchController(address admin, bytes32 salt, LaunchConfig calldata config)
        external
        returns (Deployment memory deployment);
    function predictDeployment(address deployer, bytes32 salt) external view returns (Deployment memory deployment);
}
