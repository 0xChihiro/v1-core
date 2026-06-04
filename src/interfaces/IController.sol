///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Keycode, Actions, Permissions} from "../Utils.sol";
import {IToken} from "./IToken.sol";
import {IVault} from "./IVault.sol";
import {IKernel} from "./IKernel.sol";
import {IAccessControl} from "openzeppelin/contracts/access/IAccessControl.sol";

interface IController is IAccessControl {
    enum Op {
        Add,
        Sub,
        Set
    }

    struct Backing {
        address asset;
        uint256 backingPerToken;
    }

    enum StateTransitions {
        Borrow,
        Repay,
        Redeem,
        Payment,
        Deploy,
        Recall,
        Claim,
        Deposit,
        Withdraw,
        Burn,
        StateUpdate,
        ExternalCall
    }

    struct Settlement {
        address payer;
        uint256 amount;
        StateTransitions transition;
        Receipt[] receipts;
        StateUpdate[] singleStateUpdates;
        StateUpdates[] multiStateUpdates;
        ExternalCall[] externalCalls;
    }

    struct ExternalCall {
        address target;
        bytes data;
    }

    struct Receipt {
        address asset;
        uint256 amount;
    }

    struct StateUpdate {
        Op op;
        bytes32 slot;
        bytes32 data;
    }

    struct StateUpdates {
        bytes32 startSlot;
        bytes data;
    }

    function BPS() external view returns (uint256);
    function AUCTION_FEE_BPS() external view returns (uint256);

    function TOKEN() external view returns (IToken);
    function VAULT() external view returns (IVault);
    function KERNEL() external view returns (IKernel);
    function PROTOCOL_COLLECTOR() external view returns (address);

    function CREDITOR_ROLE() external view returns (bytes32);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function MINT_PERMISSION_ROLE() external view returns (bytes32);

    function allKeycodes(uint256 index) external view returns (Keycode);
    function allKeycodesLength() external view returns (uint256);
    function activePolicies(uint256 index) external view returns (address);
    function activePoliciesLength() external view returns (uint256);
    function getDependentIndex(Keycode module, address policy) external view returns (uint256);
    function getKeycodeForModule(address module) external view returns (Keycode);
    function getPolicyDependency(address policy, uint256 index) external view returns (Keycode);
    function getPolicyDependenciesLength(address policy) external view returns (uint256);
    function getPolicyIndex(address policy) external view returns (uint256);
    function getPolicyPermission(address policy, uint256 index) external view returns (Permissions memory);
    function getPolicyPermissionsLength(address policy) external view returns (uint256);
    function mintPermissions(Keycode module) external view returns (bool);
    function moduleDependents(Keycode module, uint256 index) external view returns (address);
    function moduleDependentsLength(Keycode module) external view returns (uint256);
    function moduleDisabled(Keycode module) external view returns (bool);
    function settlementsPaused() external view returns (bool);

    function executeAction(Actions action, address target) external;
    function credit(address asset, uint256 amount, IVault.Bucket to, IVault.Bucket from) external;
    function credits(IVault.CreditCall[] calldata calls) external;
    function setMintPermission(Keycode module, bool allowed) external;
    function setModuleDisabled(Keycode module, bool disabled) external;
    function setSettlementsPaused(bool paused) external;
    function settle(Settlement[] calldata settlements) external;
    function sync(address asset, IVault.Bucket bucket) external;
    function getModuleForKeycode(Keycode module) external view returns (address);
    function modulePermissions(Keycode module, address policy, bytes4 selector) external view returns (bool);
    function isPolicyActive(address policy) external view returns (bool);

    event ActionExecuted(Actions indexed action, address indexed target);
    event Controller__Settled(address indexed module, Settlement settlement);
    event PermissionUpdated(Keycode indexed module, Keycode indexed policy, bytes4 indexed selector, bool granted);
    event MintPermissionUpdated(Keycode indexed module, bool allowed);
    event Controller__SettlementPauseUpdated(bool paused);
    event Controller__ModuleDisableUpdated(Keycode indexed module, bool disabled);

    error Controller__StateUpdatesOnly();
    error Controller__NoUpdatesGiven();
    error Controller__DifferentBackingLengths();
    error Controller__ComparingDifferentAssets();
    error Controller__BackingWentDown();
    error Controller__TransfersDuringBurn();
    error Controller__ZeroAddress();
    error Controller__TargetNotAContract(address target);
    error Controller__InvalidAdapterController();
    error Controller__ModuleAlreadyInstalled(Keycode keycode);
    error Controller__ModuleNotInstalled(Keycode keycode);
    error Controller__InvalidModuleUpgrade(Keycode keycode);
    error Controller__PolicyAlreadyActivated(address);
    error Controller__PolicyNotActivated(address);
    error Controller__DuplicateDependency(Keycode keycode);
    error Controller__PermissionDependencyNotDeclared(Keycode keycode);
    error Controller__InactiveModule();
    error Controller__SettlementsPaused();
    error Controller__ModuleDisabled(Keycode keycode);
    error Controller__MintPermissionDenied();
    error Controller__InvalidStateUpdate();
    error Controller__Locked();
    error InvalidKeycode(Keycode keycode);
    error TargetNotAContract(address target);
}
