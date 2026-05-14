///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Token} from "../Token.sol";
import {Keycode, Actions} from "../Utils.sol";
import {IVault} from "./IVault.sol";
import {IKernel} from "./IKernel.sol";

interface IController {
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
        StateUpdate
    }

    struct Settlement {
        address payer;
        uint256 amount;
        StateTransitions transition;
        Receipt[] receipts;
        StateUpdate[] singleStateUpdates;
        StateUpdates[] multiStateUpdates;
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

    function TOKEN() external view returns (Token);
    function VAULT() external view returns (IVault);
    function KERNEL() external view returns (IKernel);
    function PROTOCOL_COLLECTOR() external view returns (address);

    function CREDITOR_ROLE() external view returns (bytes32);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function MINT_PERMISSION_ROLE() external view returns (bytes32);

    function settle(Settlement[] calldata) external;
    function sync(address, IVault.Bucket) external;
    function getModuleForKeycode(Keycode) external view returns (address);
    function modulePermissions(Keycode, address, bytes4) external view returns (bool);
    function isPolicyActive(address) external view returns (bool);

    event ActionExecuted(Actions indexed action, address indexed target);
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
}
