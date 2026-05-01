///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EntenToken} from "./EntenToken.sol";
import {IController} from "./interfaces/IController.sol";
import {IKernel} from "./interfaces/IKernel.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Keycode} from "./Utils.sol";
import {Module} from "./Module.sol";
import {Slots} from "./libraries/Slots.sol";

abstract contract Dispatch is IController {
    uint256 public constant BPS = 10_000;
    uint256 public constant AUCTION_FEE_BPS = 250;

    IKernel public immutable KERNEL;
    IVault public immutable VAULT;
    EntenToken public immutable TOKEN;
    address public immutable PROTOCOL_COLLECTOR;

    mapping(Keycode => bool) public mintPermissions;

    constructor(address protocolCollector, address kernel, address vault, address token) {
        PROTOCOL_COLLECTOR = protocolCollector;
        KERNEL = IKernel(kernel);
        VAULT = IVault(vault);
        TOKEN = EntenToken(token);
    }

    function _getModuleKeycode(Module module_) internal view virtual returns (Keycode);

    function settle(Settlement[] calldata settlements) external {
        Keycode moduleKeycode = _getModuleKeycode(Module(msg.sender));
        if (Keycode.unwrap(moduleKeycode) == bytes5(0)) revert Controller__InactiveModule();

        Backing[] memory startingBacking = _backingPerToken();
        for (uint256 i = 0; i < settlements.length;) {
            Settlement calldata settlement = settlements[i];
            (IVault.TransferCall[] memory transferCalls, IVault.CreditCall[] memory creditCalls) =
                _dispatchSettlement(settlement, moduleKeycode);
            unchecked {
                i++;
            }
            if (transferCalls.length > 0) {
                VAULT.handleAccounting(transferCalls);
            }
            if (creditCalls.length > 0) {
                VAULT.credits(creditCalls);
            }
            if (settlement.singleStateUpdates.length > 0) {
                _applySingleStateUpdates(settlement.singleStateUpdates);
            }
            if (settlement.multiStateUpdates.length > 0) {
                _applyMultiStateUpdates(settlement.multiStateUpdates);
            }
        }
        Backing[] memory endingBacking = _backingPerToken();

        _validateBacking(startingBacking, endingBacking);
    }

    function _dispatchSettlement(Settlement calldata settlement, Keycode moduleKeycode)
        internal
        returns (IVault.TransferCall[] memory transferCalls, IVault.CreditCall[] memory creditCalls)
    {
        transferCalls = new IVault.TransferCall[](0);
        creditCalls = new IVault.CreditCall[](0);

        uint256 transition = uint8(settlement.transition);

        if (transition < uint8(StateTransitions.Deploy)) {
            if (transition < uint8(StateTransitions.Redeem)) {
                if (transition == uint8(StateTransitions.Borrow)) {
                    transferCalls = _buildBorrowCalls(settlement.receipts, settlement.payer);
                } else {
                    transferCalls = _buildRepayCalls(settlement.receipts, settlement.payer);
                }
            } else {
                if (transition == uint8(StateTransitions.Redeem)) {
                    TOKEN.burnFrom(settlement.payer, settlement.amount);
                    transferCalls = _buildRedeemCalls(settlement.receipts, settlement.payer);
                } else {
                    if (!mintPermissions[moduleKeycode]) revert Controller__MintPermissionDenied();
                    transferCalls = _buildPaymentTransferCalls(settlement.receipts, settlement.payer);
                    creditCalls = _buildPaymentCreditCalls(settlement.receipts);
                    TOKEN.mint(settlement.payer, settlement.amount);
                }
            }
        } else if (transition < uint8(StateTransitions.Withdraw)) {
            if (transition < uint8(StateTransitions.Claim)) {
                if (transition == uint8(StateTransitions.Deploy)) {
                    transferCalls = _buildDeployCalls(settlement.receipts, settlement.payer);
                } else {
                    transferCalls = _buildRecallCalls(settlement.receipts, settlement.payer);
                }
            } else {
                if (transition == uint8(StateTransitions.Claim)) {
                    transferCalls = _buildClaimCalls(settlement.receipts, settlement.payer);
                } else {
                    transferCalls =
                        _buildDepositCalls(settlement.receipts, settlement.payer, settlement.amount, address(TOKEN));
                }
            }
        } else {
            if (transition == uint8(StateTransitions.Withdraw)) {
                transferCalls =
                    _buildWithdrawCalls(settlement.receipts, settlement.payer, settlement.amount, address(TOKEN));
            } else if (transition == uint8(StateTransitions.Burn)) {
                if (settlement.receipts.length > 0) revert Controller__TransfersDuringBurn();
                TOKEN.burnFrom(settlement.payer, settlement.amount);
            } else if (transition == uint8(StateTransitions.StateUpdate)) {
                if (settlement.receipts.length > 0) revert Controller__StateUpdatesOnly();
                if (settlement.singleStateUpdates.length == 0 && settlement.multiStateUpdates.length == 0) {
                    revert Controller__NoUpdatesGiven();
                }
            } else {
                revert Controller__InvalidStateUpdate();
            }
        }
    }

    function _applyMultiStateUpdates(StateUpdates[] calldata updates) internal {
        for (uint256 i = 0; i < updates.length;) {
            KERNEL.updateState(updates[i].startSlot, updates[i].data);
            unchecked {
                i++;
            }
        }
    }

    function _applySingleStateUpdates(StateUpdate[] calldata updates) internal {
        IKernel.KernelCall[] memory addCalls = new IKernel.KernelCall[](updates.length);
        IKernel.KernelCall[] memory subCalls = new IKernel.KernelCall[](updates.length);
        IKernel.KernelCall[] memory setCalls = new IKernel.KernelCall[](updates.length);

        uint256 addLength;
        uint256 subLength;
        uint256 setLength;

        for (uint256 i; i < updates.length;) {
            StateUpdate memory update = updates[i];

            if (update.op == Op.Add) {
                addCalls[addLength] = IKernel.KernelCall({slot: update.slot, data: update.data});
                unchecked {
                    ++addLength;
                }
            } else if (update.op == Op.Sub) {
                subCalls[subLength] = IKernel.KernelCall({slot: update.slot, data: update.data});
                unchecked {
                    ++subLength;
                }
            } else if (update.op == Op.Set) {
                setCalls[setLength] = IKernel.KernelCall({slot: update.slot, data: update.data});
                unchecked {
                    ++setLength;
                }
            } else {
                revert Controller__InvalidStateUpdate();
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(addCalls, addLength)
            mstore(subCalls, subLength)
            mstore(setCalls, setLength)
        }

        if (addLength != 0) KERNEL.add(addCalls);
        if (subLength != 0) KERNEL.sub(subCalls);
        if (setLength != 0) KERNEL.updateState(setCalls);
    }

    function _buildBorrowCalls(Receipt[] calldata receipts, address user)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        calls = new IVault.TransferCall[](receipts.length);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: IVault.TransferType.Send,
                toBucket: IVault.Bucket.Borrow,
                fromBucket: IVault.Bucket.Redeem,
                asset: receipts[i].asset,
                user: user,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
    }

    function _buildRepayCalls(Receipt[] calldata receipts, address payer)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        calls = new IVault.TransferCall[](receipts.length);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: IVault.TransferType.Receive,
                toBucket: IVault.Bucket.Redeem,
                fromBucket: IVault.Bucket.Borrow,
                asset: receipts[i].asset,
                user: payer,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
    }

    function _buildRedeemCalls(Receipt[] calldata receipts, address payer)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        calls = new IVault.TransferCall[](receipts.length);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: IVault.TransferType.Send,
                toBucket: IVault.Bucket.None,
                fromBucket: IVault.Bucket.Redeem,
                asset: receipts[i].asset,
                user: payer,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
    }

    function _buildPaymentTransferCalls(Receipt[] calldata receipts, address payer)
        internal
        view
        returns (IVault.TransferCall[] memory calls)
    {
        calls = new IVault.TransferCall[](receipts.length * 2);
        for (uint256 i = 0; i < receipts.length;) {
            uint256 protocolFee = _mulDivUp(receipts[i].amount, AUCTION_FEE_BPS, BPS);
            uint256 offset = i * 2;

            calls[offset] = IVault.TransferCall({
                callType: IVault.TransferType.Receive,
                toBucket: IVault.Bucket.Treasury,
                fromBucket: IVault.Bucket.None,
                asset: receipts[i].asset,
                user: payer,
                amount: receipts[i].amount
            });

            calls[offset + 1] = IVault.TransferCall({
                callType: IVault.TransferType.Send,
                toBucket: IVault.Bucket.None,
                fromBucket: IVault.Bucket.Treasury,
                asset: receipts[i].asset,
                user: PROTOCOL_COLLECTOR,
                amount: protocolFee
            });

            unchecked {
                i++;
            }
        }
    }

    function _buildPaymentCreditCalls(Receipt[] calldata receipts)
        internal
        view
        returns (IVault.CreditCall[] memory calls)
    {
        uint256 teamBps = uint256(KERNEL.viewData(Slots.TEAM_PERCENTAGE_SLOT));
        uint256 treasuryBps = uint256(KERNEL.viewData(Slots.TREASURY_PERCENTAGE_SLOT));

        calls = new IVault.CreditCall[](receipts.length * 2);
        for (uint256 i = 0; i < receipts.length;) {
            uint256 protocolFee = _mulDivUp(receipts[i].amount, AUCTION_FEE_BPS, BPS);
            uint256 netAmount = receipts[i].amount - protocolFee;
            uint256 teamAmount = netAmount * teamBps / BPS;
            uint256 treasuryAmount = netAmount * treasuryBps / BPS;
            uint256 backingAmount = netAmount - teamAmount - treasuryAmount;
            uint256 offset = i * 2;

            calls[offset] = IVault.CreditCall({
                from: IVault.Bucket.Treasury, to: IVault.Bucket.Redeem, asset: receipts[i].asset, amount: backingAmount
            });

            calls[offset + 1] = IVault.CreditCall({
                from: IVault.Bucket.Treasury, to: IVault.Bucket.Team, asset: receipts[i].asset, amount: teamAmount
            });

            unchecked {
                i++;
            }
        }
    }

    function _buildDeployCalls(Receipt[] calldata receipts, address target)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        calls = new IVault.TransferCall[](receipts.length);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: IVault.TransferType.Send,
                toBucket: IVault.Bucket.None,
                fromBucket: IVault.Bucket.Treasury,
                asset: receipts[i].asset,
                user: target,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
    }

    function _buildRecallCalls(Receipt[] calldata receipts, address payer)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        calls = new IVault.TransferCall[](receipts.length);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: IVault.TransferType.Receive,
                toBucket: IVault.Bucket.Treasury,
                fromBucket: IVault.Bucket.None,
                asset: receipts[i].asset,
                user: payer,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
    }

    function _buildClaimCalls(Receipt[] calldata receipts, address target)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        calls = new IVault.TransferCall[](receipts.length);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: IVault.TransferType.Send,
                toBucket: IVault.Bucket.None,
                fromBucket: IVault.Bucket.Team,
                asset: receipts[i].asset,
                user: target,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
    }

    function _buildDepositCalls(Receipt[] calldata receipts, address target, uint256 collateralAmount, address token)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        calls = new IVault.TransferCall[](receipts.length + 1);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: IVault.TransferType.Send,
                toBucket: IVault.Bucket.Borrow,
                fromBucket: IVault.Bucket.Redeem,
                asset: receipts[i].asset,
                user: target,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }

        calls[receipts.length] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Collateral,
            fromBucket: IVault.Bucket.None,
            asset: token,
            user: target,
            amount: collateralAmount
        });
    }

    function _buildWithdrawCalls(Receipt[] calldata receipts, address target, uint256 collateralAmount, address token)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        calls = new IVault.TransferCall[](receipts.length + 1);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: IVault.TransferType.Receive,
                toBucket: IVault.Bucket.Redeem,
                fromBucket: IVault.Bucket.Borrow,
                asset: receipts[i].asset,
                user: target,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }

        calls[receipts.length] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.Collateral,
            asset: token,
            user: target,
            amount: collateralAmount
        });
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

    function _backingPerToken() internal view returns (Backing[] memory backing) {
        uint256 totalSupply = TOKEN.totalSupply();
        if (totalSupply == 0) {
            backing = new Backing[](0);
            return backing;
        }
        uint256 assetsLength = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        bytes memory rawAssets = KERNEL.viewData(Slots.ASSETS_BASE_SLOT, assetsLength);
        address[] memory assets;

        assembly ("memory-safe") {
            mstore(rawAssets, assetsLength)
            assets := rawAssets
        }

        backing = new Backing[](assets.length);

        for (uint256 i = 0; i < assets.length;) {
            uint256 redeemableBackingAmount = uint256(KERNEL.viewData(_slot(Slots.BACKING_AMOUNT_SLOT, assets[i])));
            uint256 borrowedBackingAmount =
                uint256(KERNEL.viewData(_slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, assets[i])));
            uint256 perToken = (redeemableBackingAmount + borrowedBackingAmount) * 1e18 / totalSupply;
            backing[i] = Backing({asset: assets[i], backingPerToken: perToken});
            unchecked {
                i++;
            }
        }
    }

    function _slot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }

    function _validateBacking(Backing[] memory start, Backing[] memory end) internal pure {
        if (start.length == 0) return;
        if (start.length != end.length) revert Controller__DifferentBackingLengths();
        for (uint256 i = 0; i < start.length;) {
            if (start[i].asset != end[i].asset) revert Controller__ComparingDifferentAssets();
            if (start[i].backingPerToken > end[i].backingPerToken) revert Controller__BackingWentDown();
            unchecked {
                i++;
            }
        }
    }
}
