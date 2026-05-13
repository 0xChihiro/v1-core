///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Token} from "./Token.sol";
import {IController} from "./interfaces/IController.sol";
import {IKernel} from "./interfaces/IKernel.sol";
import {IVault} from "./interfaces/IVault.sol";
import {Keycode} from "./Utils.sol";
import {Module} from "./Module.sol";
import {Slots} from "./libraries/Slots.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";

abstract contract Dispatch is IController {
    uint256 public constant BPS = 10_000;
    uint256 public constant AUCTION_FEE_BPS = 250;

    IKernel public immutable KERNEL;
    IVault public immutable VAULT;
    Token public immutable TOKEN;
    address public immutable PROTOCOL_COLLECTOR;

    mapping(Keycode => bool) public mintPermissions;
    mapping(Keycode => bool) public moduleDisabled;
    bool public settlementsPaused;

    event Controller__Settled(address indexed module, Settlement settlement);

    error Controller__Locked();

    bool private locked;

    modifier lock() {
        if (locked) revert Controller__Locked();
        locked = true;
        _;
        locked = false;
    }

    constructor(address protocolCollector, address kernel, address vault, address token) {
        PROTOCOL_COLLECTOR = protocolCollector;
        KERNEL = IKernel(kernel);
        VAULT = IVault(vault);
        TOKEN = Token(token);
    }

    function _getModuleKeycode(Module module_) internal view virtual returns (Keycode);

    function settle(Settlement[] calldata settlements) external lock {
        if (settlementsPaused) revert Controller__SettlementsPaused();

        Keycode moduleKeycode = _getModuleKeycode(Module(msg.sender));
        if (Keycode.unwrap(moduleKeycode) == bytes5(0)) revert Controller__InactiveModule();
        if (moduleDisabled[moduleKeycode]) revert Controller__ModuleDisabled(moduleKeycode);

        address[] memory assets = _assets();
        (uint256 startingSupply, uint256[] memory startingBacking) = _backingSnapshot(assets);
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
            emit Controller__Settled(msg.sender, settlement);
        }
        (uint256 endingSupply, uint256[] memory endingBacking) = _backingSnapshot(assets);

        _validateBacking(startingSupply, startingBacking, endingSupply, endingBacking);
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
                    transferCalls = _buildBorrowOrRepayCalls(settlement.receipts, settlement.payer, true);
                } else {
                    transferCalls = _buildBorrowOrRepayCalls(settlement.receipts, settlement.payer, false);
                }
            } else {
                if (transition == uint8(StateTransitions.Redeem)) {
                    TOKEN.burnFrom(settlement.payer, settlement.amount);
                    transferCalls = _buildClaimOrRedeemCalls(settlement.receipts, settlement.payer, false);
                } else {
                    if (!mintPermissions[moduleKeycode]) revert Controller__MintPermissionDenied();
                    (transferCalls, creditCalls) = _buildPaymentCalls(settlement.receipts, settlement.payer);
                    TOKEN.mint(settlement.payer, settlement.amount);
                }
            }
        } else if (transition < uint8(StateTransitions.Withdraw)) {
            if (transition < uint8(StateTransitions.Claim)) {
                if (transition == uint8(StateTransitions.Deploy)) {
                    transferCalls = _buildDeployOrRecallCalls(settlement.receipts, settlement.payer, true);
                } else {
                    transferCalls = _buildDeployOrRecallCalls(settlement.receipts, settlement.payer, false);
                }
            } else {
                if (transition == uint8(StateTransitions.Claim)) {
                    transferCalls = _buildClaimOrRedeemCalls(settlement.receipts, settlement.payer, true);
                } else {
                    transferCalls = _buildDepositOrWithdrawCalls(
                        settlement.receipts, settlement.payer, settlement.amount, address(TOKEN), true
                    );
                }
            }
        } else {
            if (transition == uint8(StateTransitions.Withdraw)) {
                transferCalls = _buildDepositOrWithdrawCalls(
                    settlement.receipts, settlement.payer, settlement.amount, address(TOKEN), false
                );
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

    function _buildBorrowOrRepayCalls(Receipt[] calldata receipts, address user, bool borrow)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        IVault.TransferType callType = borrow ? IVault.TransferType.Send : IVault.TransferType.Receive;
        IVault.Bucket toBucket = borrow ? IVault.Bucket.Borrow : IVault.Bucket.Redeem;
        IVault.Bucket fromBucket = borrow ? IVault.Bucket.Redeem : IVault.Bucket.Borrow;
        calls = new IVault.TransferCall[](receipts.length);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: callType,
                toBucket: toBucket,
                fromBucket: fromBucket,
                asset: receipts[i].asset,
                user: user,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
    }

    function _buildClaimOrRedeemCalls(Receipt[] calldata receipts, address payer, bool claim)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        IVault.Bucket fromBucket = claim ? IVault.Bucket.Team : IVault.Bucket.Redeem;
        calls = new IVault.TransferCall[](receipts.length);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: IVault.TransferType.Send,
                toBucket: IVault.Bucket.None,
                fromBucket: fromBucket,
                asset: receipts[i].asset,
                user: payer,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
    }

    function _buildPaymentCalls(Receipt[] calldata receipts, address payer)
        internal
        view
        returns (IVault.TransferCall[] memory transferCalls, IVault.CreditCall[] memory creditCalls)
    {
        uint256 teamBps = uint256(KERNEL.viewData(Slots.TEAM_PERCENTAGE_SLOT));
        uint256 treasuryBps = uint256(KERNEL.viewData(Slots.TREASURY_PERCENTAGE_SLOT));

        transferCalls = new IVault.TransferCall[](receipts.length * 2);
        creditCalls = new IVault.CreditCall[](receipts.length * 2);
        for (uint256 i = 0; i < receipts.length;) {
            uint256 protocolFee = _mulDivUp(receipts[i].amount, AUCTION_FEE_BPS, BPS);
            uint256 netAmount = receipts[i].amount - protocolFee;
            uint256 teamAmount = netAmount * teamBps / BPS;
            uint256 treasuryAmount = netAmount * treasuryBps / BPS;
            uint256 backingAmount = netAmount - teamAmount - treasuryAmount;
            uint256 offset = i * 2;

            transferCalls[offset] = IVault.TransferCall({
                callType: IVault.TransferType.Receive,
                toBucket: IVault.Bucket.Treasury,
                fromBucket: IVault.Bucket.None,
                asset: receipts[i].asset,
                user: payer,
                amount: receipts[i].amount
            });

            transferCalls[offset + 1] = IVault.TransferCall({
                callType: IVault.TransferType.Send,
                toBucket: IVault.Bucket.None,
                fromBucket: IVault.Bucket.Treasury,
                asset: receipts[i].asset,
                user: PROTOCOL_COLLECTOR,
                amount: protocolFee
            });

            creditCalls[offset] = IVault.CreditCall({
                from: IVault.Bucket.Treasury, to: IVault.Bucket.Redeem, asset: receipts[i].asset, amount: backingAmount
            });

            creditCalls[offset + 1] = IVault.CreditCall({
                from: IVault.Bucket.Treasury, to: IVault.Bucket.Team, asset: receipts[i].asset, amount: teamAmount
            });

            unchecked {
                i++;
            }
        }
    }

    function _buildDeployOrRecallCalls(Receipt[] calldata receipts, address target, bool deploy)
        internal
        pure
        returns (IVault.TransferCall[] memory calls)
    {
        IVault.TransferType callType = deploy ? IVault.TransferType.Send : IVault.TransferType.Receive;
        IVault.Bucket toBucket = deploy ? IVault.Bucket.None : IVault.Bucket.Treasury;
        IVault.Bucket fromBucket = deploy ? IVault.Bucket.Treasury : IVault.Bucket.None;
        calls = new IVault.TransferCall[](receipts.length);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: callType,
                toBucket: toBucket,
                fromBucket: fromBucket,
                asset: receipts[i].asset,
                user: target,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
    }

    function _buildDepositOrWithdrawCalls(
        Receipt[] calldata receipts,
        address target,
        uint256 collateralAmount,
        address token,
        bool deposit
    ) internal pure returns (IVault.TransferCall[] memory calls) {
        IVault.TransferType callType = deposit ? IVault.TransferType.Send : IVault.TransferType.Receive;
        IVault.Bucket toBucket = deposit ? IVault.Bucket.Borrow : IVault.Bucket.Redeem;
        IVault.Bucket fromBucket = deposit ? IVault.Bucket.Redeem : IVault.Bucket.Borrow;
        calls = new IVault.TransferCall[](receipts.length + 1);
        for (uint256 i = 0; i < receipts.length;) {
            calls[i] = IVault.TransferCall({
                callType: callType,
                toBucket: toBucket,
                fromBucket: fromBucket,
                asset: receipts[i].asset,
                user: target,
                amount: receipts[i].amount
            });
            unchecked {
                i++;
            }
        }
        calls[receipts.length] = IVault.TransferCall({
            callType: deposit ? IVault.TransferType.Receive : IVault.TransferType.Send,
            toBucket: deposit ? IVault.Bucket.Collateral : IVault.Bucket.None,
            fromBucket: deposit ? IVault.Bucket.None : IVault.Bucket.Collateral,
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

    function _assets() internal view returns (address[] memory assets) {
        uint256 assetsLength = uint256(KERNEL.viewData(Slots.ASSETS_LENGTH_SLOT));
        bytes memory rawAssets = KERNEL.viewData(Slots.ASSETS_BASE_SLOT, assetsLength);

        assembly ("memory-safe") {
            mstore(rawAssets, assetsLength)
            assets := rawAssets
        }
    }

    function _backingSnapshot(address[] memory assets)
        internal
        view
        returns (uint256 totalSupply, uint256[] memory backing)
    {
        totalSupply = TOKEN.totalSupply();
        if (totalSupply == 0) {
            backing = new uint256[](0);
            return (totalSupply, backing);
        }

        backing = new uint256[](assets.length);

        for (uint256 i = 0; i < assets.length;) {
            uint256 redeemableBackingAmount =
                uint256(KERNEL.viewData(Slots.slots(Slots.BACKING_AMOUNT_SLOT, assets[i])));
            uint256 borrowedBackingAmount =
                uint256(KERNEL.viewData(Slots.slots(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, assets[i])));
            backing[i] = redeemableBackingAmount + borrowedBackingAmount;
            unchecked {
                i++;
            }
        }
    }

    function _validateBacking(
        uint256 startingSupply,
        uint256[] memory start,
        uint256 endingSupply,
        uint256[] memory end
    ) internal pure {
        if (start.length == 0) return;
        if (start.length != end.length) revert Controller__DifferentBackingLengths();
        for (uint256 i = 0; i < start.length;) {
            uint256 requiredEndingBacking = Math.mulDiv(start[i], endingSupply, startingSupply);
            if (mulmod(start[i], endingSupply, startingSupply) != 0) {
                unchecked {
                    ++requiredEndingBacking;
                }
            }
            if (end[i] < requiredEndingBacking) revert Controller__BackingWentDown();

            unchecked {
                i++;
            }
        }
    }
}
