///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "./IController.sol";
import {IAccessControl} from "openzeppelin/contracts/access/IAccessControl.sol";

interface IProtocolCollector is IAccessControl {
    struct Adds {
        address asset;
        uint256 amount;
    }

    event ProtocolCollector__AddBacking(address indexed caller, Adds[] calls);
    event ProtocolCollector__AddTreasury(address indexed caller, Adds[] calls);
    event ProtocolCollector__ControllerAndVaultSet(address indexed controller, address indexed vault);

    error SafeERC20FailedOperation(address token);
    error ProtocolCollector__AddressesNotSet();
    error ProtocolCollector__ZeroAddressAdmin();
    error ProtocolCollector__MisconfiguredSetup();
    error ProtocolCollector__AddressesSet();

    function ADD_BACKING_ROLE() external view returns (bytes32);
    function ADD_TREASURY_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    function controller() external view returns (IController);
    function vault() external view returns (address);

    function setControllerAndVault(address controller_, address vault_) external;
    function add(Adds[] calldata calls) external;
    function addTreasury(Adds[] calldata calls) external;
}
