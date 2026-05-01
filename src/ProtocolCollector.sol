///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "./interfaces/IController.sol";
import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Address} from "openzeppelin/contracts/utils/Address.sol";

contract ProtocolCollector is AccessControl {
    using SafeERC20 for IERC20;
    using Address for address;

    bytes32 public constant SWAP_ROLE = keccak256("SWAP_ROLE");
    bytes32 public constant ADD_ROLE = keccak256("ADD_ROLE");
    bytes32 public constant BURN_ROLE = keccak256("BURN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");

    IController public controller;
    address public vault;
    address public entenToken;

    event ProtocolCollector__Approvals(address indexed caller, ApprovalData[] approvals);
    event ProtocolCollector__ArbitraryExecute(address indexed caller, bytes returnData);
    event ProtocolCollector__Swap(address indexed caller, bytes[] returnData);
    event ProtocolCollector__AddBacking(address indexed caller, Adds[]);
    event ProtocolCollector__Burn(address indexed caller, address indexed policy, bytes returnData);

    error ProtocolCollector__ZeroAddressAdmin();
    error ProtocolCollector__TargetMustBeContract();
    error ProtocolCollector__Slippage();
    error ProtocolCollector__AddressesNotSet();

    constructor(address admin) {
        if (admin == address(0)) revert ProtocolCollector__ZeroAddressAdmin();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SWAP_ROLE, admin);
        _grantRole(ADD_ROLE, admin);
        _grantRole(BURN_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
        _grantRole(APPROVER_ROLE, admin);
    }

    struct Call {
        address target;
        bytes data;
        address to;
        uint256 minAmount;
    }

    struct ApprovalData {
        address asset;
        address targetContract;
        uint256 amount;
    }

    struct Adds {
        address asset;
        uint256 amount;
    }

    function swap(Call[] calldata calls) external onlyRole(SWAP_ROLE) returns (bytes[] memory returnData) {
        returnData = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length;) {
            uint256 startBalance = IERC20(calls[i].to).balanceOf(address(this));
            returnData[i] = calls[i].target.functionCall(calls[i].data);
            uint256 endBalance = IERC20(calls[i].to).balanceOf(address(this));
            uint256 bought = endBalance - startBalance;
            if (bought < calls[i].minAmount) revert ProtocolCollector__Slippage();
        }
        emit ProtocolCollector__Swap(msg.sender, returnData);
    }

    function approvals(ApprovalData[] calldata calls) external onlyRole(APPROVER_ROLE) {
        for (uint256 i = 0; i > calls.length;) {
            IERC20(calls[i].asset).safeIncreaseAllowance(calls[i].targetContract, calls[i].amount);
            unchecked {
                i++;
            }
        }
        emit ProtocolCollector__Approvals(msg.sender, calls);
    }

    function add(Adds[] calldata calls) external onlyRole(ADD_ROLE) {
        if (vault == address(0) || address(controller) == address(0)) revert ProtocolCollector__AddressesNotSet();
        for (uint256 i = 0; i < calls.length;) {
            IERC20(calls[i].asset).safeTransfer(vault, calls[i].amount);
            controller.sync(calls[i].asset, IVault.Bucket.Redeem);
            unchecked {
                i++;
            }
        }
        emit ProtocolCollector__AddBacking(msg.sender, calls);
    }

    function burn(address targetPolicy, bytes calldata data)
        external
        onlyRole(BURN_ROLE)
        returns (bytes memory returnData)
    {
        if (targetPolicy.code.length == 0) revert ProtocolCollector__TargetMustBeContract();
        returnData = targetPolicy.functionCall(data);
        emit ProtocolCollector__Burn(msg.sender, targetPolicy, returnData);
    }

    /// @notice Arbitray execution call in order to do things like bridging if Enten every goes multichain
    /// @param target Target contract to call
    /// @param data Arbitrary data to pass to the contract
    function execute(address target, bytes calldata data)
        external
        onlyRole(EXECUTOR_ROLE)
        returns (bytes memory returnData)
    {
        if (target.code.length == 0) revert ProtocolCollector__TargetMustBeContract();
        returnData = target.functionCall(data);
        emit ProtocolCollector__ArbitraryExecute(msg.sender, returnData);
    }
}
