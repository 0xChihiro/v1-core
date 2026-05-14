///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "./interfaces/IController.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "./interfaces/IVault.sol";

interface IProtocolCollectorControllerView {
    function VAULT() external view returns (address);
    function PROTOCOL_COLLECTOR() external view returns (address);
    function CREDITOR_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract ProtocolCollector is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant ADD_BACKING_ROLE = keccak256("ADD_BACKING_ROLE");
    bytes32 public constant ADD_TREASURY_ROLE = keccak256("ADD_TREASURY_ROLE");

    IController public controller;
    address public vault;

    event ProtocolCollector__AddBacking(address indexed caller, Adds[]);
    event ProtocolCollector__AddTreasury(address indexed caller, Adds[]);
    event ProtocolCollector__ControllerAndVaultSet(address indexed controller, address indexed vault);

    error ProtocolCollector__AddressesNotSet();
    error ProtocolCollector__ZeroAddressAdmin();
    error ProtocolCollector__MisconfiguredSetup();
    error ProtocolCollector__AddressesSet();

    constructor(address admin) {
        if (admin == address(0)) revert ProtocolCollector__ZeroAddressAdmin();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADD_BACKING_ROLE, admin);
        _grantRole(ADD_TREASURY_ROLE, admin);
    }

    struct Adds {
        address asset;
        uint256 amount;
    }

    function setControllerAndVault(address _controller, address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(controller) != address(0) || vault != address(0)) revert ProtocolCollector__AddressesSet();
        if (_controller == address(0) || _vault == address(0)) revert ProtocolCollector__MisconfiguredSetup();
        if (_controller.code.length == 0 || _vault.code.length == 0) revert ProtocolCollector__MisconfiguredSetup();
        IController controllerView = IController(_controller);
        if (address(controllerView.VAULT()) != _vault) revert ProtocolCollector__MisconfiguredSetup();
        if (controllerView.PROTOCOL_COLLECTOR() != address(this)) revert ProtocolCollector__MisconfiguredSetup();
        if (!AccessControl(address(controllerView)).hasRole(controllerView.CREDITOR_ROLE(), address(this))) {
            revert ProtocolCollector__MisconfiguredSetup();
        }

        controller = IController(_controller);
        vault = _vault;

        emit ProtocolCollector__ControllerAndVaultSet(_controller, _vault);
    }

    function add(Adds[] calldata calls) external onlyRole(ADD_BACKING_ROLE) {
        _ensureAddressesSet();
        for (uint256 i = 0; i < calls.length;) {
            IERC20(calls[i].asset).safeTransfer(vault, calls[i].amount);
            controller.sync(calls[i].asset, IVault.Bucket.Redeem);
            unchecked {
                i++;
            }
        }
        emit ProtocolCollector__AddBacking(msg.sender, calls);
    }

    function addTreasury(Adds[] calldata calls) external onlyRole(ADD_TREASURY_ROLE) {
        _ensureAddressesSet();
        for (uint256 i = 0; i < calls.length;) {
            IERC20(calls[i].asset).safeTransfer(vault, calls[i].amount);
            controller.sync(calls[i].asset, IVault.Bucket.Treasury);
            unchecked {
                i++;
            }
        }
        emit ProtocolCollector__AddTreasury(msg.sender, calls);
    }

    function _ensureAddressesSet() internal view {
        if (vault == address(0) || address(controller) == address(0)) revert ProtocolCollector__AddressesNotSet();
    }
}
