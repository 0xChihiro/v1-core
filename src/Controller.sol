///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {EntenToken} from "./EntenToken.sol";
import {IController} from "./interfaces/IController.sol";
import {Keycode, Permissions, Actions, ensureContract, ensureValidKeycode} from "./Utils.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IKernel} from "./interfaces/IKernel.sol";
import {Module} from "./Module.sol";
import {Policy} from "./Policy.sol";
import {Slots} from "./libraries/Slots.sol";

contract Controller is IController, AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant AUCTION_FEE_BPS = 250;

    IKernel public immutable KERNEL;
    IVault public immutable VAULT;
    EntenToken public immutable TOKEN;
    address public immutable PROTOCOL_COLLECTOR;

    /// @notice Array of all modules currently installed.
    Keycode[] public allKeycodes;
    /// @notice Mapping of module address to keycode.
    mapping(Keycode => Module) public getModuleForKeycode;
    /// @notice Mapping of keycode to module address.
    mapping(Module => Keycode) public getKeycodeForModule;
    /// @notice Mapping of a keycode to all of its policy dependents. Used to efficiently reconfigure policy dependencies.
    mapping(Keycode => Policy[]) public moduleDependents;
    /// @notice Helper for module dependent arrays. Prevents the need to loop through array.
    mapping(Keycode => mapping(Policy => uint256)) public getDependentIndex;
    /// @notice Module <> Policy Permissions.
    /// @dev    Keycode -> Policy -> Function Selector -> bool for permission
    mapping(Keycode => mapping(Policy => mapping(bytes4 => bool))) public modulePermissions;
    /// @notice List of all active policies
    Policy[] public activePolicies;
    /// @notice Helper to get active policy quickly. Prevents need to loop through array.
    mapping(Policy => uint256) public getPolicyIndex;
    mapping(Keycode => bool) public mintPermissions;
    mapping(Keycode => mapping(bytes32 => bool)) public statePermissions;

    constructor(address admin, address protocolCollector, address kernel, address vault, address token) {
        if (
            admin == address(0) || protocolCollector == address(0) || kernel == address(0) || vault == address(0)
                || token == address(0)
        ) revert Controller__ZeroAddress();
        if (kernel.code.length == 0) revert Controller__TargetNotAContract(kernel);
        if (vault.code.length == 0) revert Controller__TargetNotAContract(vault);
        if (token.code.length == 0) revert Controller__TargetNotAContract(token);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);

        PROTOCOL_COLLECTOR = protocolCollector;
        KERNEL = IKernel(kernel);
        VAULT = IVault(vault);
        TOKEN = EntenToken(token);
    }

    modifier onlyActivePolicy() {
        _onlyActivePolicy();
        _;
    }

    modifier onlyActiveModule() {
        _onlyActiveModule();
        _;
    }

    function isPolicyActive(Policy policy_) public view returns (bool) {
        return activePolicies.length > 0 && address(activePolicies[getPolicyIndex[policy_]]) == address(policy_);
    }

    function settle(Settlement calldata settlement) external onlyActiveModule {
        Keycode moduleKeycode = getKeycodeForModule[Module(msg.sender)];
        uint256 feeBps = _feeBps(settlement);

        _validateSettlementShape(settlement);
        _validateReceipts(settlement.receipts);
        _validateCredits(settlement);
        _validateMints(moduleKeycode, settlement);
        _validateStateUpdates(moduleKeycode, settlement.stateUpdates);
        _validatePerAssetAllocation(settlement, feeBps);

        address[] memory backingAssets = _collectBackingInvariantAssets(settlement.credits);
        uint256[] memory backingBefore = _readBackingAmounts(backingAssets);
        uint256 supplyBefore = TOKEN.totalSupply();

        IVault.TransferCall[] memory transferCalls = _buildTransferCalls(settlement.payer, settlement.receipts, feeBps);
        IVault.CreditCall[] memory creditCalls = _buildCreditCalls(settlement.credits);

        if (transferCalls.length != 0) {
            VAULT.handleAccounting(transferCalls);
        }

        if (creditCalls.length != 0) {
            VAULT.credits(creditCalls);
        }

        if (settlement.stateUpdates.length != 0) {
            _applyStateUpdates(settlement.stateUpdates);
        }

        if (settlement.mints.length != 0) {
            _mintTokens(settlement.mints);
        }

        _assertBackingNonDecreasing(backingAssets, backingBefore);
        _assertMintSupplyInvariant(supplyBefore, settlement.mints);

        emit SettlementCleared(
            moduleKeycode,
            settlement.payer,
            feeBps,
            settlement.receipts.length,
            settlement.credits.length,
            settlement.mints.length,
            settlement.stateUpdates.length
        );
    }

    function _validateSettlementShape(Settlement calldata settlement) internal pure {
        bool hasReceipts = settlement.receipts.length != 0;
        bool hasCredits = settlement.credits.length != 0;
        bool hasMints = settlement.mints.length != 0;
        bool hasStateUpdates = settlement.stateUpdates.length != 0;

        if (!hasReceipts && !hasCredits && !hasMints && !hasStateUpdates) revert Controller__InvalidSettlement();
        if (hasReceipts && settlement.payer == address(0)) revert Controller__ZeroAddress();
        if (!hasReceipts && (hasCredits || hasMints)) revert Controller__InvalidSettlement();
    }

    function _validateReceipts(Receipt[] calldata receipts) internal pure {
        for (uint256 i; i < receipts.length;) {
            if (receipts[i].asset == address(0) || receipts[i].amount == 0) {
                revert Controller__InvalidSettlementAsset();
            }

            for (uint256 j = i + 1; j < receipts.length;) {
                if (receipts[i].asset == receipts[j].asset) revert Controller__InvalidSettlement();
                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    function _validateCredits(Settlement calldata settlement) internal pure {
        for (uint256 i; i < settlement.credits.length;) {
            Credit calldata credit = settlement.credits[i];
            if (credit.asset == address(0) || credit.amount == 0) revert Controller__InvalidSettlementAsset();
            if (!_hasReceiptForAsset(settlement.receipts, credit.asset)) revert Controller__InvalidSettlement();
            if (credit.to != IVault.Bucket.Redeem && credit.to != IVault.Bucket.Team) {
                revert Controller__InvalidSettlementBucket();
            }

            unchecked {
                ++i;
            }
        }
    }

    function _validateMints(Keycode moduleKeycode, Settlement calldata settlement) internal view {
        if (settlement.mints.length != 0 && !mintPermissions[moduleKeycode]) {
            revert Controller__MintPermissionDenied(moduleKeycode);
        }

        for (uint256 i; i < settlement.mints.length;) {
            Mint calldata mint = settlement.mints[i];
            if (mint.to == address(0) || mint.amount == 0) revert Controller__InvalidMint();

            unchecked {
                ++i;
            }
        }
    }

    function _validateStateUpdates(Keycode moduleKeycode, StateUpdate[] calldata updates) internal view {
        for (uint256 i; i < updates.length;) {
            StateUpdate calldata update = updates[i];
            if (update.namespace == bytes32(0)) revert Controller__InvalidStateUpdate();
            if (!_isValidStateOp(update.op)) revert Controller__InvalidStateUpdate();
            if (_isProtectedAccountingNamespace(update.namespace)) {
                revert Controller__StatePermissionDenied(update.namespace);
            }
            if (!statePermissions[moduleKeycode][update.namespace]) {
                revert Controller__StatePermissionDenied(update.namespace);
            }

            _deriveStateSlot(update);

            unchecked {
                ++i;
            }
        }
    }

    function _validatePerAssetAllocation(Settlement calldata settlement, uint256 feeBps) internal pure {
        for (uint256 i; i < settlement.receipts.length;) {
            Receipt calldata receipt = settlement.receipts[i];
            uint256 protocolFee = _mulDivUp(receipt.amount, feeBps, BPS);
            uint256 credited = _sumCredits(settlement.credits, receipt.asset);

            if (protocolFee + credited > receipt.amount) {
                revert Controller__SettlementOverAllocated(receipt.asset);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _buildTransferCalls(address payer, Receipt[] calldata receipts, uint256 feeBps)
        internal
        view
        returns (IVault.TransferCall[] memory calls)
    {
        uint256 protocolCallCount = feeBps == 0 ? 0 : receipts.length;
        calls = new IVault.TransferCall[](receipts.length + protocolCallCount);

        uint256 cursor;
        for (uint256 i; i < receipts.length;) {
            calls[cursor] = IVault.TransferCall({
                callType: IVault.TransferType.Receive,
                toBucket: IVault.Bucket.Treasury,
                fromBucket: IVault.Bucket.None,
                asset: receipts[i].asset,
                user: payer,
                amount: receipts[i].amount
            });
            unchecked {
                ++i;
                ++cursor;
            }
        }

        if (feeBps != 0) {
            for (uint256 i; i < receipts.length;) {
                uint256 protocolFee = _mulDivUp(receipts[i].amount, feeBps, BPS);
                calls[cursor] = IVault.TransferCall({
                    callType: IVault.TransferType.Send,
                    toBucket: IVault.Bucket.None,
                    fromBucket: IVault.Bucket.Treasury,
                    asset: receipts[i].asset,
                    user: PROTOCOL_COLLECTOR,
                    amount: protocolFee
                });
                unchecked {
                    ++i;
                    ++cursor;
                }
            }
        }
    }

    function _buildCreditCalls(Credit[] calldata credits) internal pure returns (IVault.CreditCall[] memory calls) {
        calls = new IVault.CreditCall[](credits.length);
        for (uint256 i; i < credits.length;) {
            calls[i] = IVault.CreditCall({
                from: IVault.Bucket.Treasury, to: credits[i].to, asset: credits[i].asset, amount: credits[i].amount
            });
            unchecked {
                ++i;
            }
        }
    }

    function _applyStateUpdates(StateUpdate[] calldata updates) internal {
        for (uint256 i; i < updates.length;) {
            StateUpdate calldata update = updates[i];
            bytes32 slot = _deriveStateSlot(update);

            if (update.op == StateOp.Set) {
                KERNEL.updateState(slot, update.data);
            } else if (update.op == StateOp.Add) {
                KERNEL.add(slot, update.data);
            } else if (update.op == StateOp.Sub) {
                KERNEL.sub(slot, update.data);
            } else {
                revert Controller__InvalidStateUpdate();
            }

            unchecked {
                ++i;
            }
        }
    }

    function _mintTokens(Mint[] calldata mints) internal {
        for (uint256 i; i < mints.length;) {
            TOKEN.mint(mints[i].to, mints[i].amount);
            unchecked {
                ++i;
            }
        }
    }

    function _feeBps(Settlement calldata settlement) internal pure returns (uint256) {
        if (settlement.mints.length == 0) return 0;
        return AUCTION_FEE_BPS;
    }

    function _hasReceiptForAsset(Receipt[] calldata receipts, address asset) internal pure returns (bool) {
        for (uint256 i; i < receipts.length;) {
            if (receipts[i].asset == asset) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _sumCredits(Credit[] calldata credits, address asset) internal pure returns (uint256 total) {
        for (uint256 i; i < credits.length;) {
            if (credits[i].asset == asset) total += credits[i].amount;
            unchecked {
                ++i;
            }
        }
    }

    function _collectBackingInvariantAssets(Credit[] calldata credits) internal view returns (address[] memory assets) {
        address[] memory registeredAssets = _readRegisteredAssets();
        uint256 count = registeredAssets.length;
        for (uint256 i; i < credits.length;) {
            if (credits[i].to == IVault.Bucket.Redeem) ++count;
            unchecked {
                ++i;
            }
        }

        assets = new address[](count);
        uint256 cursor;
        for (uint256 i; i < registeredAssets.length;) {
            address asset = registeredAssets[i];
            if (asset != address(0) && !_containsAsset(assets, cursor, asset)) {
                assets[cursor] = asset;
                unchecked {
                    ++cursor;
                }
            }
            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < credits.length;) {
            if (credits[i].to == IVault.Bucket.Redeem) {
                address asset = credits[i].asset;
                if (!_containsAsset(assets, cursor, asset)) {
                    assets[cursor] = asset;
                    unchecked {
                        ++cursor;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(assets, cursor)
        }
    }

    function _readRegisteredAssets() internal view returns (address[] memory assets) {
        uint256 assetCount = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        if (assetCount == 0) return new address[](0);

        bytes memory raw = KERNEL.viewData(Slots.ASSETS_BASE_SLOT, assetCount);

        assembly ("memory-safe") {
            mstore(raw, assetCount)
            assets := raw
        }
    }

    function _containsAsset(address[] memory assets, uint256 length, address asset) internal pure returns (bool) {
        for (uint256 i; i < length;) {
            if (assets[i] == asset) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _readBackingAmounts(address[] memory assets) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length;) {
            amounts[i] = uint256(KERNEL.viewData(_amountSlot(IVault.Bucket.Redeem, assets[i])));
            unchecked {
                ++i;
            }
        }
    }

    function _assertBackingNonDecreasing(address[] memory assets, uint256[] memory beforeAmounts) internal view {
        for (uint256 i; i < assets.length;) {
            uint256 afterAmount = uint256(KERNEL.viewData(_amountSlot(IVault.Bucket.Redeem, assets[i])));
            if (afterAmount < beforeAmounts[i]) {
                revert Controller__BackingInvariantBreach(assets[i], beforeAmounts[i], afterAmount);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _assertMintSupplyInvariant(uint256 supplyBefore, Mint[] calldata mints) internal view {
        uint256 minted;
        for (uint256 i; i < mints.length;) {
            minted += mints[i].amount;
            unchecked {
                ++i;
            }
        }

        uint256 supplyAfter = TOKEN.totalSupply();
        if (supplyAfter != supplyBefore + minted) revert Controller__InvalidMint();

        if (minted != 0) {
            uint256 maxSupply = uint256(KERNEL.viewData(Slots.MAX_SUPPLY_SLOT));
            if (supplyAfter > maxSupply) revert Controller__MintExceedsMaxSupply(supplyAfter, maxSupply);
        }
    }

    function _deriveStateSlot(StateUpdate calldata update) internal pure returns (bytes32 slot) {
        if (update.derivation == SlotDerivation.Direct) {
            if (update.key != bytes32(0)) revert Controller__InvalidStateUpdate();
            return update.namespace;
        }

        if (update.derivation == SlotDerivation.MappingKey) {
            return _mappedSlot(update.namespace, update.key);
        }

        if (update.derivation == SlotDerivation.Offset) {
            return bytes32(uint256(update.namespace) + uint256(update.key));
        }

        revert Controller__InvalidStateUpdate();
    }

    function _mappedSlot(bytes32 namespace, bytes32 key) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, key)
            slot := keccak256(0x00, 0x40)
        }
    }

    function _amountSlot(IVault.Bucket bucket, address asset) internal pure returns (bytes32 slot) {
        bytes32 namespace = _namespace(bucket);
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }

    function _namespace(IVault.Bucket bucket) internal pure returns (bytes32 namespace) {
        if (bucket == IVault.Bucket.Redeem) return Slots.BACKING_AMOUNT_SLOT;
        if (bucket == IVault.Bucket.Treasury) return Slots.TREASURY_AMOUNT_SLOT;
        if (bucket == IVault.Bucket.Team) return Slots.TEAM_AMOUNT_SLOT;
        if (bucket == IVault.Bucket.Borrow) return Slots.ASSET_TOTAL_BORROWED_BASE_SLOT;
        if (bucket == IVault.Bucket.Collateral) return Slots.TOTAL_COLLATERL_SLOT;
        revert Controller__InvalidSettlementBucket();
    }

    function _isProtectedAccountingNamespace(bytes32 namespace) internal pure returns (bool) {
        return namespace == Slots.BACKING_AMOUNT_SLOT || namespace == Slots.TREASURY_AMOUNT_SLOT
            || namespace == Slots.TEAM_AMOUNT_SLOT || namespace == Slots.ASSET_TOTAL_BORROWED_BASE_SLOT
            || namespace == Slots.TOTAL_COLLATERL_SLOT;
    }

    function _isValidStateOp(StateOp op) internal pure returns (bool) {
        return op == StateOp.Set || op == StateOp.Add || op == StateOp.Sub;
    }

    function _setPolicyPermissions(Policy policy, Permissions[] memory requests, bool granted) internal {
        Keycode policyKeycode = policy.KEYCODE();
        for (uint256 i; i < requests.length;) {
            Permissions memory request = requests[i];
            if (address(getModuleForKeycode[request.keycode]) == address(0)) {
                revert Controller__ModuleNotInstalled(request.keycode);
            }

            modulePermissions[request.keycode][policy][request.funcSelector] = granted;

            emit PermissionUpdated(request.keycode, policyKeycode, request.funcSelector, granted);

            unchecked {
                ++i;
            }
        }
    }

    function _onlyActivePolicy() internal view {
        if (!isPolicyActive(Policy(msg.sender))) revert Controller__InactivePolicy();
    }

    function _onlyActiveModule() internal view {
        Keycode keycode = getKeycodeForModule[Module(msg.sender)];
        if (_isEmptyKeycode(keycode)) revert Controller__InactiveModule();
    }

    function _activePolicyForKeycode(Keycode keycode) internal view returns (Policy policy) {
        for (uint256 i; i < activePolicies.length;) {
            policy = activePolicies[i];
            if (Keycode.unwrap(policy.KEYCODE()) == Keycode.unwrap(keycode)) return policy;
            unchecked {
                ++i;
            }
        }
    }

    function _isEmptyKeycode(Keycode keycode) internal pure returns (bool) {
        return Keycode.unwrap(keycode) == bytes5(0);
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        uint256 product = x * y;
        uint256 result = product / denominator;
        if (product % denominator != 0) {
            unchecked {
                ++result;
            }
        }
        return result;
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

        if (address(getModuleForKeycode[keycode]) != address(0)) {
            revert Controller__ModuleAlreadyInstalled(keycode);
        }

        getModuleForKeycode[keycode] = newModule;
        getKeycodeForModule[newModule] = keycode;
        allKeycodes.push(keycode);

        newModule.INIT();
    }

    function _upgradeModule(Module newModule) internal {
        Keycode keycode = newModule.KEYCODE();
        Module oldModule = getModuleForKeycode[keycode];

        if (address(oldModule) == address(0) || address(oldModule) == address(newModule)) {
            revert Controller__InvalidModuleUpgrade(keycode);
        }

        getKeycodeForModule[oldModule] = Keycode.wrap(bytes5(0));
        getKeycodeForModule[newModule] = keycode;
        getModuleForKeycode[keycode] = newModule;

        newModule.INIT();

        _reconfigurePolicies(keycode);
    }

    function _activatePolicy(Policy policy) internal {
        if (isPolicyActive(policy)) revert Controller__PolicyAlreadyActivated(address(policy));

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
        if (!isPolicyActive(policy)) revert Controller__PolicyNotActivated(address(policy));

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
        if (address(getModuleForKeycode[module]) == address(0)) revert Controller__ModuleNotInstalled(module);

        mintPermissions[module] = allowed;

        emit MintPermissionUpdated(module, allowed);
    }

    function setStatePermission(Keycode module, bytes32 namespace, bool allowed) external onlyRole(EXECUTOR_ROLE) {
        if (address(getModuleForKeycode[module]) == address(0)) revert Controller__ModuleNotInstalled(module);
        if (namespace == bytes32(0)) revert Controller__InvalidStateUpdate();
        if (_isProtectedAccountingNamespace(namespace)) revert Controller__StatePermissionDenied(namespace);

        statePermissions[module][namespace] = allowed;

        emit StatePermissionUpdated(module, namespace, allowed);
    }
}
