///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {EntenToken} from "./EntenToken.sol";
import {Kernel} from "./Kernel.sol";
import {Vault} from "./Vault.sol";
import {IController, IModule, IPolicy, Keycode, Permission} from "./interfaces/IController.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IKernel} from "./interfaces/IKernel.sol";
import {Slots} from "./libraries/Slots.sol";

contract Controller is IController, AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant AUCTION_FEE_BPS = 250;

    IKernel public immutable KERNEL;
    IVault public immutable VAULT;
    EntenToken public immutable TOKEN;
    address public immutable PROTOCOL_COLLECTOR;

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

    Keycode[] public allModuleKeycodes;
    Keycode[] public allPolicyKeycodes;

    mapping(Keycode keycode => address module) public moduleForKeycode;
    mapping(address module => Keycode keycode) public keycodeForModule;
    mapping(Keycode keycode => bool active) public activeModules;

    mapping(Keycode keycode => address policy) public policyForKeycode;
    mapping(address policy => Keycode keycode) public keycodeForPolicy;
    mapping(Keycode keycode => bool active) public activePolicies;

    mapping(Keycode policy => Keycode[] dependencies) public policyDependencies;
    mapping(Keycode module => mapping(Keycode policy => mapping(bytes4 selector => bool allowed))) public
        policyPermissions;
    mapping(Keycode module => bool allowed) public mintPermissions;
    mapping(Keycode module => mapping(bytes32 namespace => bool allowed)) public statePermissions;

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

    event ActionExecuted(Action indexed action, address indexed target);
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
    error Controller__PolicyAlreadyActive(Keycode keycode);
    error Controller__PolicyNotActive(Keycode keycode);
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

    constructor(address admin, address protocolCollector) {
        if (admin == address(0) || protocolCollector == address(0)) revert Controller__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);

        PROTOCOL_COLLECTOR = protocolCollector;
        KERNEL = IKernel(new Kernel(address(this)));
        VAULT = IVault(new Vault(address(this), address(KERNEL)));
        TOKEN = new EntenToken("Enten", "ENTEN", address(this), address(0), 0, type(uint256).max);
        KERNEL.setAccountingWriter(address(VAULT));
    }

    modifier onlyActivePolicy() {
        _onlyActivePolicy();
        _;
    }

    modifier onlyActiveModule() {
        _onlyActiveModule();
        _;
    }

    function execute(Action action, address target) external onlyRole(EXECUTOR_ROLE) {
        if (action == Action.InstallModule) {
            _installModule(target);
        } else if (action == Action.UpgradeModule) {
            _upgradeModule(target);
        } else if (action == Action.ActivateModule) {
            _activateModule(target);
        } else if (action == Action.InstallPolicy) {
            _installPolicy(target);
        } else if (action == Action.UpgradePolicy) {
            _upgradePolicy(target);
        } else if (action == Action.ActivatePolicy) {
            _activatePolicy(target);
        }

        emit ActionExecuted(action, target);
    }

    function moduleKeycodeAt(uint256 index) external view returns (Keycode) {
        return allModuleKeycodes[index];
    }

    function policyKeycodeAt(uint256 index) external view returns (Keycode) {
        return allPolicyKeycodes[index];
    }

    function policyDependencyAt(Keycode policy, uint256 index) external view returns (Keycode) {
        return policyDependencies[policy][index];
    }

    function setMintPermission(Keycode module, bool allowed) external onlyRole(EXECUTOR_ROLE) {
        if (moduleForKeycode[module] == address(0)) revert Controller__ModuleNotInstalled(module);
        if (!activeModules[module]) revert Controller__ModuleNotActive(module);

        mintPermissions[module] = allowed;

        emit MintPermissionUpdated(module, allowed);
    }

    function setStatePermission(Keycode module, bytes32 namespace, bool allowed) external onlyRole(EXECUTOR_ROLE) {
        if (moduleForKeycode[module] == address(0)) revert Controller__ModuleNotInstalled(module);
        if (!activeModules[module]) revert Controller__ModuleNotActive(module);
        if (namespace == bytes32(0)) revert Controller__InvalidStateUpdate();
        if (_isProtectedAccountingNamespace(namespace)) revert Controller__StatePermissionDenied(namespace);

        statePermissions[module][namespace] = allowed;

        emit StatePermissionUpdated(module, namespace, allowed);
    }

    function settle(Settlement calldata settlement) external onlyActiveModule {
        Keycode moduleKeycode = keycodeForModule[msg.sender];
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

    function _installModule(address target) internal {
        _ensureContract(target);

        Keycode keycode = IModule(target).keycode();
        _ensureValidKeycode(keycode);

        if (moduleForKeycode[keycode] != address(0)) revert Controller__ModuleAlreadyInstalled(keycode);

        moduleForKeycode[keycode] = target;
        keycodeForModule[target] = keycode;
        allModuleKeycodes.push(keycode);

        IModule(target).init();

        emit ModuleInstalled(keycode, target);
    }

    function _upgradeModule(address target) internal {
        _ensureContract(target);

        Keycode keycode = IModule(target).keycode();
        _ensureValidKeycode(keycode);

        address oldModule = moduleForKeycode[keycode];
        if (oldModule == address(0) || oldModule == target) revert Controller__InvalidModuleUpgrade(keycode);

        keycodeForModule[oldModule] = Keycode.wrap(bytes5(0));
        moduleForKeycode[keycode] = target;
        keycodeForModule[target] = keycode;

        IModule(target).init();

        emit ModuleUpgraded(keycode, oldModule, target);
    }

    function _activateModule(address target) internal {
        Keycode keycode = keycodeForModule[target];
        if (_isEmptyKeycode(keycode)) revert Controller__ModuleNotInstalled(keycode);
        if (activeModules[keycode]) revert Controller__ModuleAlreadyActive(keycode);

        activeModules[keycode] = true;

        emit ModuleStatusUpdated(keycode, target, true);
    }

    function _installPolicy(address target) internal {
        _ensureContract(target);

        Keycode keycode = IPolicy(target).keycode();
        _ensureValidKeycode(keycode);

        if (policyForKeycode[keycode] != address(0)) revert Controller__PolicyAlreadyInstalled(keycode);

        policyForKeycode[keycode] = target;
        keycodeForPolicy[target] = keycode;
        allPolicyKeycodes.push(keycode);

        emit PolicyInstalled(keycode, target);
    }

    function _upgradePolicy(address target) internal {
        _ensureContract(target);

        Keycode keycode = IPolicy(target).keycode();
        _ensureValidKeycode(keycode);

        address oldPolicy = policyForKeycode[keycode];
        if (oldPolicy == address(0) || oldPolicy == target) revert Controller__InvalidPolicyUpgrade(keycode);

        bool wasActive = activePolicies[keycode];
        if (wasActive) _deactivatePolicy(oldPolicy);

        keycodeForPolicy[oldPolicy] = Keycode.wrap(bytes5(0));
        policyForKeycode[keycode] = target;
        keycodeForPolicy[target] = keycode;

        if (wasActive) _activatePolicy(target);

        emit PolicyUpgraded(keycode, oldPolicy, target);
    }

    function _activatePolicy(address target) internal {
        Keycode policyKeycode = keycodeForPolicy[target];
        if (_isEmptyKeycode(policyKeycode)) revert Controller__PolicyNotInstalled(policyKeycode);
        if (activePolicies[policyKeycode]) revert Controller__PolicyAlreadyActive(policyKeycode);

        delete policyDependencies[policyKeycode];
        Keycode[] memory dependencies = IPolicy(target).configureDependencies();
        for (uint256 i; i < dependencies.length;) {
            Keycode dependency = dependencies[i];
            if (moduleForKeycode[dependency] == address(0)) revert Controller__ModuleNotInstalled(dependency);
            if (!activeModules[dependency]) revert Controller__ModuleNotActive(dependency);
            policyDependencies[policyKeycode].push(dependency);
            unchecked {
                ++i;
            }
        }

        Permission[] memory requests = IPolicy(target).requestPermissions();
        _setPolicyPermissions(policyKeycode, requests, true);
        activePolicies[policyKeycode] = true;

        emit PolicyStatusUpdated(policyKeycode, target, true);
    }

    function _deactivatePolicy(address target) internal {
        Keycode policyKeycode = keycodeForPolicy[target];
        if (_isEmptyKeycode(policyKeycode)) revert Controller__PolicyNotInstalled(policyKeycode);
        if (!activePolicies[policyKeycode]) revert Controller__PolicyNotActive(policyKeycode);

        Permission[] memory requests = IPolicy(target).requestPermissions();
        _setPolicyPermissions(policyKeycode, requests, false);

        delete policyDependencies[policyKeycode];
        activePolicies[policyKeycode] = false;

        emit PolicyStatusUpdated(policyKeycode, target, false);
    }

    function _setPolicyPermissions(Keycode policyKeycode, Permission[] memory requests, bool granted) internal {
        for (uint256 i; i < requests.length;) {
            Permission memory request = requests[i];
            if (moduleForKeycode[request.keycode] == address(0)) {
                revert Controller__ModuleNotInstalled(request.keycode);
            }
            if (!activeModules[request.keycode]) revert Controller__ModuleNotActive(request.keycode);

            policyPermissions[request.keycode][policyKeycode][request.selector] = granted;

            emit PermissionUpdated(request.keycode, policyKeycode, request.selector, granted);

            unchecked {
                ++i;
            }
        }
    }

    function _onlyActivePolicy() internal view {
        Keycode keycode = keycodeForPolicy[msg.sender];
        if (_isEmptyKeycode(keycode) || !activePolicies[keycode]) revert Controller__InactivePolicy();
    }

    function _onlyActiveModule() internal view {
        Keycode keycode = keycodeForModule[msg.sender];
        if (_isEmptyKeycode(keycode) || !activeModules[keycode]) revert Controller__InactiveModule();
    }

    function _ensureContract(address target) internal view {
        if (target.code.length == 0) revert Controller__TargetNotAContract(target);
    }

    function _ensureValidKeycode(Keycode keycode) internal pure {
        bytes5 raw = Keycode.unwrap(keycode);
        for (uint256 i; i < 5;) {
            bytes1 char = raw[i];
            if (char < 0x41 || char > 0x5A) revert Controller__InvalidKeycode(keycode);
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
}
