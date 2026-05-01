///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {Dispatch} from "./Dispatch.sol";
import {Keycode, Permissions, Actions, ensureContract, ensureValidKeycode} from "./Utils.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Module} from "./Module.sol";
import {Policy} from "./Policy.sol";
import {Slots} from "./libraries/Slots.sol";

contract Controller is Dispatch, AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant CREDITOR_ROLE = keccak256("CREDITOR_ROLE");

    /// @notice Array of all modules currently installed.
    Keycode[] public allKeycodes;
    /// @notice Mapping of keycode to module address.
    mapping(Keycode => Module) internal _moduleForKeycode;
    /// @notice Mapping of module address to keycode.
    mapping(Module => Keycode) public getKeycodeForModule;
    /// @notice Mapping of a keycode to all of its policy dependents. Used to efficiently reconfigure policy dependencies.
    mapping(Keycode => Policy[]) public moduleDependents;
    /// @notice Helper for module dependent arrays. Prevents the need to loop through array.
    mapping(Keycode => mapping(Policy => uint256)) public getDependentIndex;
    /// @notice Module <> Policy Permissions.
    /// @dev    Keycode -> Policy -> Function Selector -> bool for permission
    mapping(Keycode => mapping(Policy => mapping(bytes4 => bool))) internal _modulePermissions;
    /// @notice List of all active policies
    Policy[] public activePolicies;
    /// @notice Helper to get active policy quickly. Prevents need to loop through array.
    mapping(Policy => uint256) public getPolicyIndex;

    constructor(address admin, address protocolCollector, address kernel, address vault, address token)
        Dispatch(protocolCollector, kernel, vault, token)
    {
        if (
            admin == address(0) || protocolCollector == address(0) || kernel == address(0) || vault == address(0)
                || token == address(0)
        ) revert Controller__ZeroAddress();
        if (kernel.code.length == 0) revert Controller__TargetNotAContract(kernel);
        if (vault.code.length == 0) revert Controller__TargetNotAContract(vault);
        if (token.code.length == 0) revert Controller__TargetNotAContract(token);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
    }

    function getModuleForKeycode(Keycode keycode) public view override returns (address) {
        return address(_moduleForKeycode[keycode]);
    }

    function modulePermissions(Keycode keycode, address policy, bytes4 selector) public view override returns (bool) {
        return _modulePermissions[keycode][Policy(policy)][selector];
    }

    function isPolicyActive(address policy_) public view override returns (bool) {
        return _isPolicyActive(Policy(policy_));
    }

    function _isPolicyActive(Policy policy_) internal view returns (bool) {
        return activePolicies.length > 0 && address(activePolicies[getPolicyIndex[policy_]]) == address(policy_);
    }

    function credit(address asset, uint256 amount, IVault.Bucket to, IVault.Bucket from)
        external
        onlyRole(CREDITOR_ROLE)
    {
        VAULT.credit(asset, amount, from, to);
    }

    function credits(IVault.CreditCall[] calldata calls) external onlyRole(CREDITOR_ROLE) {
        VAULT.credits(calls);
    }

    function sync(address asset, IVault.Bucket bucket) external onlyRole(CREDITOR_ROLE) {
        VAULT.syncSurplus(asset, bucket);
    }

    function _setPolicyPermissions(Policy policy, Permissions[] memory requests, bool granted) internal {
        Keycode policyKeycode = policy.KEYCODE();
        for (uint256 i; i < requests.length;) {
            Permissions memory request = requests[i];
            if (address(_moduleForKeycode[request.keycode]) == address(0)) {
                revert Controller__ModuleNotInstalled(request.keycode);
            }

            _modulePermissions[request.keycode][policy][request.funcSelector] = granted;

            emit PermissionUpdated(request.keycode, policyKeycode, request.funcSelector, granted);

            unchecked {
                ++i;
            }
        }
    }

    function _getModuleKeycode(Module module_) internal view override returns (Keycode) {
        return getKeycodeForModule[module_];
    }

    // @notice Main Controller function. Initiates state changes to controller depending on Action passed in.
    function executeAction(Actions action, address target) external onlyRole(EXECUTOR_ROLE) {
        if (action == Actions.InstallModule) {
            ensureContract(target);
            ensureValidKeycode(Module(target).KEYCODE());
            _installModule(Module(target));
        } else if (action == Actions.UpgradeModule) {
            ensureContract(target);
            ensureValidKeycode(Module(target).KEYCODE());
            _upgradeModule(Module(target));
        } else if (action == Actions.ActivatePolicy) {
            ensureContract(target);
            _activatePolicy(Policy(target));
        } else if (action == Actions.DeactivatePolicy) {
            ensureContract(target);
            _deactivatePolicy(Policy(target));
        }
        emit ActionExecuted(action, target);
    }

    function _installModule(Module newModule) internal {
        Keycode keycode = newModule.KEYCODE();

        if (address(_moduleForKeycode[keycode]) != address(0)) {
            revert Controller__ModuleAlreadyInstalled(keycode);
        }

        _moduleForKeycode[keycode] = newModule;
        getKeycodeForModule[newModule] = keycode;
        allKeycodes.push(keycode);

        newModule.INIT();
    }

    function _upgradeModule(Module newModule) internal {
        Keycode keycode = newModule.KEYCODE();
        Module oldModule = _moduleForKeycode[keycode];

        if (address(oldModule) == address(0) || address(oldModule) == address(newModule)) {
            revert Controller__InvalidModuleUpgrade(keycode);
        }

        getKeycodeForModule[oldModule] = Keycode.wrap(bytes5(0));
        getKeycodeForModule[newModule] = keycode;
        _moduleForKeycode[keycode] = newModule;

        newModule.INIT();

        _reconfigurePolicies(keycode);
    }

    function _activatePolicy(Policy policy) internal {
        if (_isPolicyActive(policy)) revert Controller__PolicyAlreadyActivated(address(policy));

        // Add policy to list of active policies
        activePolicies.push(policy);
        getPolicyIndex[policy] = activePolicies.length - 1;

        // Record module dependencies
        Keycode[] memory dependencies = policy.configureDependencies();
        uint256 depLength = dependencies.length;

        for (uint256 i; i < depLength;) {
            Keycode keycode = dependencies[i];

            moduleDependents[keycode].push(policy);
            getDependentIndex[keycode][policy] = moduleDependents[keycode].length - 1;

            unchecked {
                ++i;
            }
        }

        // Grant permissions for policy to access restricted module functions
        Permissions[] memory requests = policy.requestPermissions();
        _setPolicyPermissions(policy, requests, true);
    }

    function _deactivatePolicy(Policy policy) internal {
        if (!_isPolicyActive(policy)) revert Controller__PolicyNotActivated(address(policy));

        // Revoke permissions
        Permissions[] memory requests = policy.requestPermissions();
        _setPolicyPermissions(policy, requests, false);

        // Remove policy from all policy data structures
        uint256 idx = getPolicyIndex[policy];
        Policy lastPolicy = activePolicies[activePolicies.length - 1];

        activePolicies[idx] = lastPolicy;
        activePolicies.pop();
        getPolicyIndex[lastPolicy] = idx;
        delete getPolicyIndex[policy];

        // Remove policy from module dependents
        _pruneFromDependents(policy);
    }

    function _reconfigurePolicies(Keycode keycode) internal {
        Policy[] memory dependents = moduleDependents[keycode];
        uint256 depLength = dependents.length;

        for (uint256 i; i < depLength;) {
            dependents[i].configureDependencies();

            unchecked {
                ++i;
            }
        }
    }

    function _pruneFromDependents(Policy policy) internal {
        Keycode[] memory dependencies = policy.configureDependencies();
        uint256 depcLength = dependencies.length;

        for (uint256 i; i < depcLength;) {
            Keycode keycode = dependencies[i];
            Policy[] storage dependents = moduleDependents[keycode];

            uint256 origIndex = getDependentIndex[keycode][policy];
            Policy lastPolicy = dependents[dependents.length - 1];

            // Swap with last and pop
            dependents[origIndex] = lastPolicy;
            dependents.pop();

            // Record new index and delete deactivated policy index
            getDependentIndex[keycode][lastPolicy] = origIndex;
            delete getDependentIndex[keycode][policy];

            unchecked {
                ++i;
            }
        }
    }

    function setMintPermission(Keycode module, bool allowed) external onlyRole(EXECUTOR_ROLE) {
        if (address(_moduleForKeycode[module]) == address(0)) revert Controller__ModuleNotInstalled(module);

        mintPermissions[module] = allowed;

        emit MintPermissionUpdated(module, allowed);
    }

    function setStatePermission(Keycode module, bytes32 namespace, bool allowed) external onlyRole(EXECUTOR_ROLE) {
        if (address(_moduleForKeycode[module]) == address(0)) revert Controller__ModuleNotInstalled(module);
        if (namespace == bytes32(0)) revert Controller__InvalidStateUpdate();
        if (_isProtectedAccountingNamespace(namespace)) revert Controller__StatePermissionDenied(namespace);

        statePermissions[module][namespace] = allowed;

        emit StatePermissionUpdated(module, namespace, allowed);
    }

    function _isProtectedAccountingNamespace(bytes32 namespace) internal pure returns (bool) {
        return namespace == Slots.BACKING_AMOUNT_SLOT || namespace == Slots.TREASURY_AMOUNT_SLOT
            || namespace == Slots.TEAM_AMOUNT_SLOT || namespace == Slots.ASSET_TOTAL_BORROWED_BASE_SLOT
            || namespace == Slots.TOTAL_COLLATERL_SLOT;
    }
}
