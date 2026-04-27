pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {Keycode} from "./src/interfaces/IController.sol";
import {IKernel} from "./src/interfaces/IKernel.sol";
import {IVault} from "./src/interfaces/IVault.sol";
import {Slots} from "./src/libraries/Slots.sol";

interface IEntenToken {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

contract ControllerSettlementSketch is AccessControl {
    uint256 public constant BPS = 10_000;
    uint256 public constant AUCTION_FEE_BPS = 250;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    IKernel public immutable KERNEL;
    IVault public immutable VAULT;
    IEntenToken public immutable TOKEN;
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

    mapping(Keycode module => address moduleAddress) public moduleForKeycode;
    mapping(address moduleAddress => Keycode module) public keycodeForModule;
    mapping(Keycode module => bool active) public activeModules;
    mapping(Keycode module => bool allowed) public mintPermissions;
    mapping(Keycode module => mapping(bytes32 namespace => bool allowed)) public statePermissions;

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
    error Controller__ModuleNotInstalled(Keycode module);
    error Controller__ModuleNotActive(Keycode module);
    error Controller__InactiveModule();
    error Controller__MintPermissionDenied(Keycode module);
    error Controller__StatePermissionDenied(bytes32 namespace);
    error Controller__InvalidStateUpdate();
    error Controller__InvalidSettlement();
    error Controller__InvalidSettlementAsset();
    error Controller__InvalidSettlementBucket();
    error Controller__InvalidMint();
    error Controller__MintExceedsMaxSupply(uint256 supplyAfter, uint256 maxSupply);
    error Controller__SettlementOverAllocated(address asset);
    error Controller__BackingInvariantBreach(address asset, uint256 beforeAmount, uint256 afterAmount);

    constructor(address kernel, address vault, address token, address protocolCollector) {
        if (kernel == address(0) || vault == address(0) || token == address(0)) revert Controller__ZeroAddress();

        KERNEL = IKernel(kernel);
        VAULT = IVault(vault);
        TOKEN = IEntenToken(token);
        PROTOCOL_COLLECTOR = protocolCollector;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
    }

    modifier onlyActiveModule() {
        _onlyActiveModule();
        _;
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

        address[] memory backingAssets = _collectBackingCreditAssets(settlement.credits);
        uint256[] memory backingBefore = _readBackingAmounts(backingAssets);
        uint256 supplyBefore = TOKEN.totalSupply();

        IVault.ReceiveCall[] memory receiveCalls = _buildReceiveCalls(settlement.payer, settlement.receipts);
        IVault.TreasuryCall[] memory protocolCalls = _buildProtocolFeeCalls(settlement.receipts, feeBps);
        IVault.CreditCall[] memory creditCalls = _buildCreditCalls(settlement.credits);

        if (receiveCalls.length != 0) {
            VAULT.receiveAssets(receiveCalls);
        }

        if (protocolCalls.length != 0) {
            VAULT.transferTreasuryAssets(protocolCalls);
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

    function _onlyActiveModule() internal view {
        Keycode moduleKeycode = keycodeForModule[msg.sender];
        if (Keycode.unwrap(moduleKeycode) == bytes5(0) || !activeModules[moduleKeycode]) {
            revert Controller__InactiveModule();
        }
    }

    function _validateSettlementShape(Settlement calldata settlement) internal pure {
        bool hasReceipts = settlement.receipts.length != 0;
        bool hasCredits = settlement.credits.length != 0;
        bool hasMints = settlement.mints.length != 0;
        bool hasStateUpdates = settlement.stateUpdates.length != 0;

        if (!hasReceipts && !hasCredits && !hasMints && !hasStateUpdates) {
            revert Controller__InvalidSettlement();
        }

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
            if (credit.to != IVault.Bucket.Backing && credit.to != IVault.Bucket.Team) {
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

    function _buildReceiveCalls(
        address payer,
        Receipt[] calldata receipts
    ) internal pure returns (IVault.ReceiveCall[] memory calls) {
        calls = new IVault.ReceiveCall[](receipts.length);
        for (uint256 i; i < receipts.length;) {
            calls[i] = IVault.ReceiveCall({
                from: payer,
                asset: receipts[i].asset,
                amount: receipts[i].amount,
                bucket: IVault.Bucket.Treasury
            });
            unchecked {
                ++i;
            }
        }
    }

    function _buildProtocolFeeCalls(
        Receipt[] calldata receipts,
        uint256 feeBps
    ) internal view returns (IVault.TreasuryCall[] memory calls) {
        if (feeBps == 0) return new IVault.TreasuryCall[](0);

        calls = new IVault.TreasuryCall[](receipts.length);
        for (uint256 i; i < receipts.length;) {
            uint256 protocolFee = _mulDivUp(receipts[i].amount, feeBps, BPS);
            calls[i] = IVault.TreasuryCall({
                asset: receipts[i].asset,
                to: PROTOCOL_COLLECTOR,
                amount: protocolFee
            });
            unchecked {
                ++i;
            }
        }
    }

    function _buildCreditCalls(Credit[] calldata credits) internal pure returns (IVault.CreditCall[] memory calls) {
        calls = new IVault.CreditCall[](credits.length);
        for (uint256 i; i < credits.length;) {
            calls[i] = IVault.CreditCall({
                from: IVault.Bucket.Treasury,
                to: credits[i].to,
                asset: credits[i].asset,
                amount: credits[i].amount
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

    function _collectBackingCreditAssets(Credit[] calldata credits) internal pure returns (address[] memory assets) {
        uint256 count;
        for (uint256 i; i < credits.length;) {
            if (credits[i].to == IVault.Bucket.Backing) ++count;
            unchecked {
                ++i;
            }
        }

        assets = new address[](count);
        uint256 cursor;
        for (uint256 i; i < credits.length;) {
            if (credits[i].to == IVault.Bucket.Backing) {
                assets[cursor] = credits[i].asset;
                unchecked {
                    ++cursor;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _readBackingAmounts(address[] memory assets) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length;) {
            amounts[i] = uint256(KERNEL.viewData(_amountSlot(IVault.Bucket.Backing, assets[i])));
            unchecked {
                ++i;
            }
        }
    }

    function _assertBackingNonDecreasing(address[] memory assets, uint256[] memory beforeAmounts) internal view {
        for (uint256 i; i < assets.length;) {
            uint256 afterAmount = uint256(KERNEL.viewData(_amountSlot(IVault.Bucket.Backing, assets[i])));
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
        if (bucket == IVault.Bucket.Backing) return Slots.BACKING_AMOUNT_SLOT;
        if (bucket == IVault.Bucket.Treasury) return Slots.TREASURY_AMOUNT_SLOT;
        if (bucket == IVault.Bucket.Team) return Slots.TEAM_AMOUNT_SLOT;
        revert Controller__InvalidSettlementBucket();
    }

    function _isProtectedAccountingNamespace(bytes32 namespace) internal pure returns (bool) {
        return namespace == Slots.BACKING_AMOUNT_SLOT
            || namespace == Slots.TREASURY_AMOUNT_SLOT
            || namespace == Slots.TEAM_AMOUNT_SLOT;
    }

    function _isValidStateOp(StateOp op) internal pure returns (bool) {
        return op == StateOp.Set || op == StateOp.Add || op == StateOp.Sub;
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
