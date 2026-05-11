///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IControllerFactory {
    struct Deployment {
        address controller;
        address kernel;
        address vault;
        address token;
    }

    struct LaunchConfig {
        string tokenName;
        string tokenSymbol;
        address preMineAddress;
        uint256 preMineAmount;
        uint256 maxSupply;
    }

    struct CreationCodeStores {
        address controller;
        address kernel;
        address vault;
        address token;
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
    error ControllerFactory__InvalidCreationCodeStore();

    function launchController(address admin, bytes32 salt, LaunchConfig calldata config)
        external
        returns (Deployment memory deployment);
    function predictDeployment(address deployer, bytes32 salt) external view returns (Deployment memory deployment);
}
