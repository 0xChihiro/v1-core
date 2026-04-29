///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IKernel} from "./interfaces/IKernel.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Slots} from "./libraries/Slots.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vault is IVault {
    using SafeERC20 for IERC20;

    // ---------------------- IMMUTABLES  -------------------------------------- \\
    address public immutable CONTROLLER;
    IKernel public immutable KERNEL;

    // ---------------------- EVENTS -------------------------------------------- \\
    event SurplusSynced(address indexed asset, Bucket indexed bucket, uint256 amount);

    // ---------------------- ERRORS -------------------------------------------- \\
    error Vault__BackingCallInvalid();
    error Vault__CannotLowerBacking();
    error Vault__InvalidBucket();
    error Vault__MisconfiguredSetup();
    error Vault__NoSurplus();
    error Vault__OnlyController();
    error Vault__InvalidTransferType();

    constructor(address controller, address kernel) {
        if (controller == address(0) || kernel == address(0)) revert Vault__MisconfiguredSetup();
        CONTROLLER = controller;
        KERNEL = IKernel(kernel);
    }

    modifier onlyController() {
        _onlyController();
        _;
    }

    function _onlyController() internal view {
        if (msg.sender != CONTROLLER) revert Vault__OnlyController();
    }

    function handleAccounting(TransferCall[] memory calls) external onlyController {
        uint256 addIndex;
        uint256 subIndex;
        IKernel.KernelCall[] memory addCalls = new IKernel.KernelCall[](calls.length);
        IKernel.KernelCall[] memory subCalls = new IKernel.KernelCall[](calls.length);

        for (uint256 i; i < calls.length;) {
            TransferCall memory call = calls[i];

            if (call.callType == TransferType.Receive) {
                if (call.toBucket == Bucket.None) revert Vault__InvalidBucket();
            } else if (call.callType == TransferType.Send) {
                if (call.fromBucket == Bucket.None) revert Vault__InvalidBucket();
            } else {
                revert Vault__InvalidTransferType();
            }

            if (call.fromBucket != Bucket.None) {
                subCalls[subIndex] =
                    IKernel.KernelCall({slot: _bucketSlot(call.fromBucket, call.asset), data: bytes32(call.amount)});
                unchecked {
                    ++subIndex;
                }
            }

            if (call.toBucket != Bucket.None) {
                addCalls[addIndex] =
                    IKernel.KernelCall({slot: _bucketSlot(call.toBucket, call.asset), data: bytes32(call.amount)});
                unchecked {
                    ++addIndex;
                }
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(addCalls, addIndex)
            mstore(subCalls, subIndex)
        }

        if (addIndex != 0) KERNEL.add(addCalls);
        if (subIndex != 0) KERNEL.sub(subCalls);

        for (uint256 i; i < calls.length;) {
            TransferCall memory call = calls[i];

            if (call.callType == TransferType.Receive) {
                IERC20(call.asset).safeTransferFrom(call.user, address(this), call.amount);
            } else if (call.callType == TransferType.Send) {
                IERC20(call.asset).safeTransfer(call.user, call.amount);
            } else {
                revert Vault__InvalidTransferType();
            }

            unchecked {
                ++i;
            }
        }
    }

    function credit(address asset, uint256 amount, Bucket from, Bucket to) external onlyController {
        if (from == Bucket.Redeem || from == Bucket.Borrow) revert Vault__CannotLowerBacking();
        KERNEL.sub(_bucketSlot(from, asset), bytes32(amount));
        KERNEL.add(_bucketSlot(to, asset), bytes32(amount));
    }

    function credits(CreditCall[] calldata calls) external onlyController {
        IKernel.KernelCall[] memory subCalls = new IKernel.KernelCall[](calls.length);
        IKernel.KernelCall[] memory addCalls = new IKernel.KernelCall[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].from == Bucket.Redeem || calls[i].from == Bucket.Borrow) revert Vault__CannotLowerBacking();
            subCalls[i] =
                IKernel.KernelCall({slot: _bucketSlot(calls[i].from, calls[i].asset), data: bytes32(calls[i].amount)});
            addCalls[i] =
                IKernel.KernelCall({slot: _bucketSlot(calls[i].to, calls[i].asset), data: bytes32(calls[i].amount)});
        }
        KERNEL.sub(subCalls);
        KERNEL.add(addCalls);
    }

    function syncSurplus(address asset, Bucket bucket) external onlyController {
        uint256 actualBalance = IERC20(asset).balanceOf(address(this));
        uint256 accounted = _accountedBalance(asset);

        if (actualBalance <= accounted) revert Vault__NoSurplus();

        uint256 surplus = actualBalance - accounted;
        KERNEL.add(_bucketSlot(bucket, asset), bytes32(surplus));

        emit SurplusSynced(asset, bucket, surplus);
    }

    // ---------------------- VIEW FUNCTIONS ------------------------------------ \\
    function _accountedBalance(address asset) internal view returns (uint256 total) {
        total = uint256(KERNEL.viewData(_backingAmountSlot(asset)))
            + uint256(KERNEL.viewData(_treasuryAmountSlot(asset))) + uint256(KERNEL.viewData(_teamAmountSlot(asset)));
    }

    function backingBalances() external view returns (IVault.AssetBalance[] memory) {
        return _readAssetBalances(Slots.BACKING_AMOUNT_SLOT);
    }

    function treasuryBalances() external view returns (IVault.AssetBalance[] memory) {
        return _readAssetBalances(Slots.TREASURY_AMOUNT_SLOT);
    }

    function teamBalances() external view returns (IVault.AssetBalance[] memory) {
        return _readAssetBalances(Slots.TEAM_AMOUNT_SLOT);
    }

    // ---------------------- INTERNAL FUNCTIONS -------------------------------- \\
    function _treasuryAmountSlot(address asset) internal pure returns (bytes32 slot) {
        return _bucketSlot(Bucket.Treasury, asset);
    }

    function _backingAmountSlot(address asset) internal pure returns (bytes32 slot) {
        return _bucketSlot(Bucket.Redeem, asset);
    }

    function _teamAmountSlot(address asset) internal pure returns (bytes32 slot) {
        return _bucketSlot(Bucket.Team, asset);
    }

    function _bucketSlot(Bucket bucket, address asset) internal pure returns (bytes32 slot) {
        bytes32 namespace;

        if (bucket == Bucket.Borrow) {
            namespace = Slots.ASSET_TOTAL_BORROWED_BASE_SLOT;
        } else if (bucket == Bucket.Redeem) {
            namespace = Slots.BACKING_AMOUNT_SLOT;
        } else if (bucket == Bucket.Treasury) {
            namespace = Slots.TREASURY_AMOUNT_SLOT;
        } else if (bucket == Bucket.Team) {
            namespace = Slots.TEAM_AMOUNT_SLOT;
        } else if (bucket == Bucket.Collateral) {
            namespace = Slots.TOTAL_COLLATERL_SLOT;
        } else {
            revert Vault__InvalidBucket();
        }

        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }

    function _slot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }

    function _readAssets() internal view returns (address[] memory assets) {
        uint256 assetCount = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        if (assetCount == 0) return new address[](0);

        bytes memory raw = KERNEL.viewData(Slots.ASSETS_BASE_SLOT, assetCount);

        assembly ("memory-safe") {
            mstore(raw, assetCount)
            assets := raw
        }
    }

    function _readAssetBalances(bytes32 namespace) internal view returns (IVault.AssetBalance[] memory values) {
        uint256 assetCount = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        values = new IVault.AssetBalance[](assetCount);
        if (assetCount == 0) return values;

        bytes memory rawAssets = KERNEL.viewData(Slots.ASSETS_BASE_SLOT, assetCount);
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
