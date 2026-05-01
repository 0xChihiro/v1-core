///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Keycode, Actions} from "../Utils.sol";
import {IVault} from "./IVault.sol";

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

    function settle(Settlement[] calldata) external;
    function sync(address, IVault.Bucket) external;
    function getModuleForKeycode(Keycode) external view returns (address);
    function modulePermissions(Keycode, address, bytes4) external view returns (bool);
    function isPolicyActive(address) external view returns (bool);

    event ActionExecuted(Actions indexed action, address indexed target);
    event PermissionUpdated(Keycode indexed module, Keycode indexed policy, bytes4 indexed selector, bool granted);
    event MintPermissionUpdated(Keycode indexed module, bool allowed);

    error Controller__StateUpdatesOnly();
    error Controller__NoUpdatesGiven();
    error Controller__DifferentBackingLengths();
    error Controller__ComparingDifferentAssets();
    error Controller__BackingWentDown();
    error Controller__TransfersDuringBurn();
    error Controller__ZeroAddress();
    error Controller__TargetNotAContract(address target);
    error Controller__ModuleAlreadyInstalled(Keycode keycode);
    error Controller__ModuleNotInstalled(Keycode keycode);
    error Controller__InvalidModuleUpgrade(Keycode keycode);
    error Controller__PolicyAlreadyActivated(address);
    error Controller__PolicyNotActivated(address);
    error Controller__DuplicateDependency(Keycode keycode);
    error Controller__InactiveModule();
    error Controller__MintPermissionDenied();
    error Controller__InvalidStateUpdate();
}
