///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Keycode, Actions} from "../Utils.sol";
import {Module} from "../Module.sol";
import {Policy} from "../Policy.sol";
import {IVault} from "./IVault.sol";

interface IController {
    enum StateOp {
        Set,
        Add,
        Sub
    }

    enum SlotDerivation {
        Direct,
        MappingKey,
        Offset
    }

    struct Settlement {
        address payer;
        Receipt[] receipts;
        Credit[] credits;
        Mint[] mints;
        StateUpdate[] stateUpdates;
    }

    struct Receipt {
        address asset;
        uint256 amount;
    }

    struct Credit {
        address asset;
        IVault.Bucket to;
        uint256 amount;
    }

    struct Mint {
        address to;
        uint256 amount;
    }

    struct StateUpdate {
        bytes32 namespace;
        SlotDerivation derivation;
        bytes32 key;
        StateOp op;
        bytes32 data;
    }

    function getModuleForKeycode(Keycode) external view returns (Module);
    function modulePermissions(Keycode, Policy, bytes4) external view returns (bool);
    function isPolicyActive(Policy) external view returns (bool);

    event ActionExecuted(Actions indexed action, address indexed target);
    event ModuleInstalled(Keycode indexed keycode, address indexed module);
    event ModuleUpgraded(Keycode indexed keycode, address indexed oldModule, address indexed newModule);
    event ModuleStatusUpdated(Keycode indexed keycode, address indexed module, bool active);
    event PolicyInstalled(Keycode indexed keycode, address indexed policy);
    event PolicyUpgraded(Keycode indexed keycode, address indexed oldPolicy, address indexed newPolicy);
    event PolicyStatusUpdated(Keycode indexed keycode, address indexed policy, bool active);
    event PermissionUpdated(Keycode indexed module, Keycode indexed policy, bytes4 indexed selector, bool granted);
    event MintPermissionUpdated(Keycode indexed module, bool allowed);
    event StatePermissionUpdated(Keycode indexed module, bytes32 indexed namespace, bool allowed);
    event SettlementCleared(
        Keycode indexed module,
        address indexed payer,
        uint256 feeBps,
        uint256 receiptCount,
        uint256 creditCount,
        uint256 mintCount,
        uint256 stateUpdateCount
    );

    error Controller__ZeroAddress();
    error Controller__TargetNotAContract(address target);
    error Controller__InvalidKeycode(Keycode keycode);
    error Controller__ModuleAlreadyInstalled(Keycode keycode);
    error Controller__ModuleNotInstalled(Keycode keycode);
    error Controller__ModuleAlreadyActive(Keycode keycode);
    error Controller__ModuleNotActive(Keycode keycode);
    error Controller__InvalidModuleUpgrade(Keycode keycode);
    error Controller__PolicyAlreadyInstalled(Keycode keycode);
    error Controller__PolicyNotInstalled(Keycode keycode);
    error Controller__PolicyAlreadyActivated(address);
    error Controller__PolicyNotActivated(address);
    error Controller__InvalidPolicyUpgrade(Keycode keycode);
    error Controller__InactivePolicy();
    error Controller__InactiveModule();
    error Controller__MintPermissionDenied(Keycode keycode);
    error Controller__StatePermissionDenied(bytes32 namespace);
    error Controller__InvalidStateUpdate();
    error Controller__InvalidSettlement();
    error Controller__InvalidSettlementAsset();
    error Controller__InvalidSettlementBucket();
    error Controller__InvalidMint();
    error Controller__MintExceedsMaxSupply(uint256 supplyAfter, uint256 maxSupply);
    error Controller__SettlementOverAllocated(address asset);
    error Controller__BackingInvariantBreach(address asset, uint256 beforeAmount, uint256 afterAmount);
}
