///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IController} from "./interfaces/IController.sol";
import {IKernel} from "./interfaces/IKernel.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vault is IVault {
    using SafeERC20 for IERC20;

    // ---------------------- KERNEL WRITE / READ SLOTS  ---------------------- \\
    bytes32 internal constant TREASURY_AMOUNT_SLOT = 0x60b5ab302bbeea0c83917cc1819e272c0b2ec70ceb2f138a32d5caae015750f3; //equivilant to keccak256("enten.treasury.amount");
    bytes32 internal constant BACKING_AMOUNT_SLOT = 0x0024fb7f9ccb99221958049f86297fab788b0f0b640b3f50254c9bd56ccf0930; // equivilant to keccak256("enten.backing.amount");
    bytes32 internal constant TEAM_AMOUNT_SLOT = 0x1da01d8de7381a167e82accc7aa1ccc9122c1143bd9e81a0e9456adadd05678a; // equivilant to keccak256("enten.team.amount");
    bytes32 internal constant ASSET_COUNT_SLOT = 0xd635f114cc21f2834e679c2555d4ff475d8d6f01003ca6da1dfee13ecdf62738; // equiviliant to keccak256("enten.backing.assets.length");
    bytes32 internal constant ASSET_BASE_SLOT = 0x1a27d05721698994f0e5408d30550ae696157097140b4a919a081b62c08e625f; // equivilant to keccak256("enten.backing.assets");

    // ---------------------- IMMUTABLES  -------------------------------------- \\
    IController public immutable CONTROLLER;
    IKernel public immutable KERNEL;

    // ---------------------- EVENTS -------------------------------------------- \\
    event SurplusSynced(address indexed asset, Bucket indexed bucket, uint256 amount);

    // ---------------------- ERRORS -------------------------------------------- \\
    error Vault__CannotLowerBacking();
    error Vault__ExceedsTreasuryBalance();
    error Vault__InvalidBucket();
    error Vault__MisconfiguredSetup();
    error Vault__NoSurplus();
    error Vault__RestrictedAccess();

    constructor(address controller, address kernel) {
        if (controller == address(0) || kernel == address(0)) revert Vault__MisconfiguredSetup();
        CONTROLLER = IController(controller);
        KERNEL = IKernel(kernel);
    }

    function transferTreasuryAsset(IVault.TreasuryCall calldata call) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();
        bytes32 slot = _treasuryAmountSlot(call.asset);
        IERC20(call.asset).safeTransfer(call.to, call.amount);
        KERNEL.sub(slot, bytes32(call.amount));
    }

    function transferTreasuryAssets(IVault.TreasuryCall[] calldata calls) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();
        IKernel.KernelCall[] memory updateCalls = new IKernel.KernelCall[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            bytes32 slot = _treasuryAmountSlot(calls[i].asset);
            IERC20(calls[i].asset).safeTransfer(calls[i].to, calls[i].amount);
            updateCalls[i] = IKernel.KernelCall({slot: slot, data: bytes32(calls[i].amount)});
        }
        KERNEL.sub(updateCalls);
    }

    function transferRedeem(address to, IVault.RedeemCall[] calldata calls) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();
        IKernel.KernelCall[] memory updateCalls = new IKernel.KernelCall[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            bytes32 slot = _backingAmountSlot(calls[i].asset);
            IERC20(calls[i].asset).safeTransfer(to, calls[i].amount);
            updateCalls[i] = IKernel.KernelCall({slot: slot, data: bytes32(calls[i].amount)});
        }
        KERNEL.sub(updateCalls);
    }

    function transferTeamAsset(TeamCall calldata call) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();
        bytes32 slot = _teamAmountSlot(call.asset);
        KERNEL.sub(slot, bytes32(call.amount));
        IERC20(call.asset).safeTransfer(call.to, call.amount);
    }

    function transferTeamAssets(TeamCall[] calldata calls) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();
        IKernel.KernelCall[] memory updateCalls = new IKernel.KernelCall[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            bytes32 slot = _teamAmountSlot(calls[i].asset);
            IERC20(calls[i].asset).safeTransfer(calls[i].to, calls[i].amount);
            updateCalls[i] = IKernel.KernelCall({slot: slot, data: bytes32(calls[i].amount)});
        }
        KERNEL.sub(updateCalls);
    }

    function receiveAsset(IVault.ReceiveCall calldata call) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();
        IERC20(call.asset).safeTransferFrom(call.from, address(this), call.amount);
        KERNEL.add(_amountSlot(call.bucket, call.asset), bytes32(call.amount));
    }

    function receiveAssets(IVault.ReceiveCall[] calldata calls) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();
        IKernel.KernelCall[] memory updateCalls = new IKernel.KernelCall[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            IERC20(calls[i].asset).safeTransferFrom(calls[i].from, address(this), calls[i].amount);
            updateCalls[i] = IKernel.KernelCall({
                slot: _amountSlot(calls[i].bucket, calls[i].asset), data: bytes32(calls[i].amount)
            });
        }
        KERNEL.add(updateCalls);
    }

    function credit(address asset, uint256 amount, Bucket from, Bucket to) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();
        if (from == Bucket.Backing) revert Vault__CannotLowerBacking();
        bytes32 fromSlot = _amountSlot(from, asset);
        bytes32 toSlot = _amountSlot(to, asset);
        KERNEL.add(toSlot, bytes32(amount));
        KERNEL.sub(fromSlot, bytes32(amount));
    }

    function credits(CreditCall[] memory calls) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();
        IKernel.KernelCall[] memory addCalls = new IKernel.KernelCall[](calls.length);
        IKernel.KernelCall[] memory subCalls = new IKernel.KernelCall[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].from == Bucket.Backing) revert Vault__CannotLowerBacking();
            bytes32 toSlot = _amountSlot(calls[i].to, calls[i].asset);
            bytes32 fromSlot = _amountSlot(calls[i].from, calls[i].asset);
            addCalls[i] = IKernel.KernelCall({slot: toSlot, data: bytes32(calls[i].amount)});
            subCalls[i] = IKernel.KernelCall({slot: fromSlot, data: bytes32(calls[i].amount)});
        }
        KERNEL.sub(subCalls);
        KERNEL.add(addCalls);
    }

    function syncSurplus(address asset, Bucket bucket) external {
        if (!CONTROLLER.vaultAccess(msg.sender)) revert Vault__RestrictedAccess();

        uint256 actualBalance = IERC20(asset).balanceOf(address(this));
        uint256 accounted = _accountedBalance(asset);

        if (actualBalance <= accounted) revert Vault__NoSurplus();

        uint256 surplus = actualBalance - accounted;
        KERNEL.add(_amountSlot(bucket, asset), bytes32(surplus));

        emit SurplusSynced(asset, bucket, surplus);
    }

    // ---------------------- VIEW FUNCTIONS ------------------------------------ \\
    function _accountedBalance(address asset) internal view returns (uint256 total) {
        total = uint256(KERNEL.viewData(_backingAmountSlot(asset)))
            + uint256(KERNEL.viewData(_treasuryAmountSlot(asset))) + uint256(KERNEL.viewData(_teamAmountSlot(asset)));
    }

    function backingBalances() external view returns (IVault.AssetBalance[] memory) {
        return _readAssetBalances(BACKING_AMOUNT_SLOT);
    }

    function treasuryBalances() external view returns (IVault.AssetBalance[] memory) {
        return _readAssetBalances(TREASURY_AMOUNT_SLOT);
    }

    function teamBalances() external view returns (IVault.AssetBalance[] memory) {
        return _readAssetBalances(TEAM_AMOUNT_SLOT);
    }

    // ---------------------- INTERNAL FUNCTIONS -------------------------------- \\
    function _treasuryAmountSlot(address asset) internal pure returns (bytes32 slot) {
        return _amountSlot(IVault.Bucket.Treasury, asset);
    }

    function _backingAmountSlot(address asset) internal pure returns (bytes32 slot) {
        return _amountSlot(IVault.Bucket.Backing, asset);
    }

    function _teamAmountSlot(address asset) internal pure returns (bytes32 slot) {
        return _amountSlot(IVault.Bucket.Team, asset);
    }

    function _namespace(IVault.Bucket bucket) internal pure returns (bytes32 namespace) {
        if (bucket == IVault.Bucket.Backing) return BACKING_AMOUNT_SLOT;
        if (bucket == IVault.Bucket.Treasury) return TREASURY_AMOUNT_SLOT;
        if (bucket == IVault.Bucket.Team) return TEAM_AMOUNT_SLOT;
        revert Vault__InvalidBucket();
    }

    function _amountSlot(IVault.Bucket bucket, address asset) internal pure returns (bytes32 slot) {
        bytes32 namespace = _namespace(bucket);
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }

    function _readAssets() internal view returns (address[] memory assets) {
        uint256 assetCount = uint256(KERNEL.viewData(ASSET_COUNT_SLOT));
        if (assetCount == 0) return new address[](0);

        bytes memory raw = KERNEL.viewData(ASSET_BASE_SLOT, assetCount);

        assembly ("memory-safe") {
            mstore(raw, assetCount)
            assets := raw
        }
    }

    function _readAssetBalances(bytes32 namespace) internal view returns (IVault.AssetBalance[] memory values) {
        uint256 assetCount = uint256(KERNEL.viewData(ASSET_COUNT_SLOT));
        values = new IVault.AssetBalance[](assetCount);
        if (assetCount == 0) return values;

        bytes memory rawAssets = KERNEL.viewData(ASSET_BASE_SLOT, assetCount);
        bytes32[] memory slots;

        for (uint256 i = 0; i < assetCount;) {
            address asset;
            assembly ("memory-safe") {
                let assetPtr := add(add(rawAssets, 0x20), shl(5, i))
                let assetWord := and(mload(assetPtr), 0xffffffffffffffffffffffffffffffffffffffff)
                asset := assetWord
                mstore(0x00, namespace)
                mstore(0x20, assetWord)
                mstore(assetPtr, keccak256(0x00, 0x40))
            }
            values[i].asset = asset;
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(rawAssets, assetCount)
            slots := rawAssets
        }

        bytes32[] memory responses = KERNEL.viewData(slots);
        for (uint256 i = 0; i < assetCount;) {
            values[i].amount = uint256(responses[i]);
            unchecked {
                ++i;
            }
        }
    }
}
