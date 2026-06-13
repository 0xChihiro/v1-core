///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Controller} from "../src/Controller.sol";
import {Module} from "../src/Module.sol";
import {IController} from "../src/interfaces/IController.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {Slots} from "../src/libraries/Slots.sol";
import {Keycode} from "../src/Utils.sol";
import {Math} from "openzeppelin/contracts/utils/math/Math.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";

contract ControllerKernelMock {
    mapping(bytes32 => bytes32) internal data;

    function setRaw(bytes32 slot, bytes32 value) external {
        data[slot] = value;
    }

    function viewData(bytes32 slot) external view returns (bytes32) {
        return data[slot];
    }

    function viewData(bytes32 startSlot, uint256 nSlots) external view returns (bytes memory values) {
        values = new bytes(nSlots * 32);
        for (uint256 i; i < nSlots;) {
            bytes32 value = data[bytes32(uint256(startSlot) + i)];
            assembly ("memory-safe") {
                mstore(add(add(values, 0x20), shl(5, i)), value)
            }
            unchecked {
                ++i;
            }
        }
    }
}

contract ControllerVaultMock {
    function validateBalances(address[] calldata) external pure {}
}

contract ControllerTokenMock {
    address public controller;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    error ControllerTokenMock__OnlyController();
    error ControllerTokenMock__InsufficientBalance();

    function setController(address controller_) external {
        controller = controller_;
    }

    function setBalance(address account, uint256 amount) external {
        totalSupply = totalSupply - balanceOf[account] + amount;
        balanceOf[account] = amount;
    }

    function mint(address account, uint256 amount) external onlyController {
        totalSupply += amount;
        balanceOf[account] += amount;
    }

    function burnFrom(address account, uint256 amount) external onlyController {
        if (balanceOf[account] < amount) revert ControllerTokenMock__InsufficientBalance();
        balanceOf[account] -= amount;
        totalSupply -= amount;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert ControllerTokenMock__OnlyController();
        _;
    }
}

contract ControllerHalmosHarness is Controller {
    constructor(address admin, address protocolCollector, address kernel, address vault, address token)
        Controller(admin, protocolCollector, kernel, vault, token, 0)
    {}

    function forceModule(Keycode keycode, Module module_) external {
        getKeycodeForModule[address(module_)] = keycode;
    }

    function forceMintPermission(Keycode keycode, bool allowed) external {
        mintPermissions[keycode] = allowed;
    }

    function exposedDispatch(IController.Settlement calldata settlement, Keycode keycode)
        external
        returns (IVault.TransferCall[] memory transferCalls, IVault.CreditCall[] memory creditCalls)
    {
        return _dispatchSettlement(settlement, keycode, _assets());
    }

    function exposedValidateBacking(
        uint256 startingSupply,
        uint256[] memory start,
        uint256 endingSupply,
        uint256[] memory end
    ) external pure {
        _validateBacking(startingSupply, start, endingSupply, end);
    }
}

contract ControllerHalmosModule is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("HLMOS"));
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    function settle(IController.Settlement[] calldata settlements) external {
        CONTROLLER.settle(settlements);
    }
}

contract ControllerHalmosTest is Test, SymTest {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant AUCTION_FEE_BPS = 250;

    address internal constant ADMIN = address(0xAD);
    address internal constant COLLECTOR = address(0xC011EC70);
    address internal constant USER = address(0xA11CE);
    address internal constant ASSET = address(0xA55E7);

    ControllerKernelMock internal kernel;
    ControllerVaultMock internal vault;
    ControllerTokenMock internal token;
    ControllerHalmosHarness internal controller;
    ControllerHalmosModule internal module;

    function setUp() public {
        kernel = new ControllerKernelMock();
        vault = new ControllerVaultMock();
        token = new ControllerTokenMock();
        controller = new ControllerHalmosHarness(ADMIN, COLLECTOR, address(kernel), address(vault), address(token));
        token.setController(address(controller));

        module = new ControllerHalmosModule(address(controller));
        controller.forceModule(module.KEYCODE(), module);
        controller.forceMintPermission(module.KEYCODE(), true);
    }

    function check_controllerBorrowRepayDispatchBuckets() public {
        uint256 amount = svm.createUint(96, "controller borrow repay amount");

        IController.Settlement memory borrow =
            _settlement(IController.StateTransitions.Borrow, 0, _oneReceipt(ASSET, amount));
        (IVault.TransferCall[] memory borrowCalls,) = controller.exposedDispatch(borrow, module.KEYCODE());
        _assertTransferCall(
            borrowCalls[0], IVault.TransferType.Send, IVault.Bucket.Borrow, IVault.Bucket.Redeem, ASSET, USER, amount
        );

        IController.Settlement memory repay =
            _settlement(IController.StateTransitions.Repay, 0, _oneReceipt(ASSET, amount));
        (IVault.TransferCall[] memory repayCalls,) = controller.exposedDispatch(repay, module.KEYCODE());
        _assertTransferCall(
            repayCalls[0], IVault.TransferType.Receive, IVault.Bucket.Redeem, IVault.Bucket.Borrow, ASSET, USER, amount
        );
    }

    function check_controllerDepositWithdrawDispatchBuckets() public {
        uint256 backingAmount = svm.createUint(96, "controller deposit backing amount");
        uint256 collateralAmount = svm.createUint(96, "controller deposit collateral amount");

        IController.Settlement memory deposit =
            _settlement(IController.StateTransitions.Deposit, collateralAmount, _oneReceipt(ASSET, backingAmount));
        (IVault.TransferCall[] memory depositCalls,) = controller.exposedDispatch(deposit, module.KEYCODE());
        _assertTransferCall(
            depositCalls[0],
            IVault.TransferType.Send,
            IVault.Bucket.Borrow,
            IVault.Bucket.Redeem,
            ASSET,
            USER,
            backingAmount
        );
        _assertTransferCall(
            depositCalls[1],
            IVault.TransferType.Receive,
            IVault.Bucket.Collateral,
            IVault.Bucket.None,
            address(token),
            USER,
            collateralAmount
        );

        IController.Settlement memory withdraw =
            _settlement(IController.StateTransitions.Withdraw, collateralAmount, _oneReceipt(ASSET, backingAmount));
        (IVault.TransferCall[] memory withdrawCalls,) = controller.exposedDispatch(withdraw, module.KEYCODE());
        _assertTransferCall(
            withdrawCalls[0],
            IVault.TransferType.Receive,
            IVault.Bucket.Redeem,
            IVault.Bucket.Borrow,
            ASSET,
            USER,
            backingAmount
        );
        _assertTransferCall(
            withdrawCalls[1],
            IVault.TransferType.Send,
            IVault.Bucket.None,
            IVault.Bucket.Collateral,
            address(token),
            USER,
            collateralAmount
        );
    }

    function check_controllerPaymentSplitAndFeeRouting() public {
        uint256 receiptAmount = svm.createUint(96, "controller payment receipt amount");
        uint256 mintAmount = svm.createUint(96, "controller payment mint amount");
        uint256 teamBps = svm.createUint(14, "controller payment team bps");
        uint256 treasuryBps = svm.createUint(14, "controller payment treasury bps");

        vm.assume(teamBps <= BPS);
        vm.assume(treasuryBps <= BPS);
        vm.assume(teamBps + treasuryBps <= BPS);

        _assertPaymentSplitAndFeeRouting(receiptAmount, mintAmount, teamBps, treasuryBps);
    }

    function check_controllerBackingValidationUsesCeiling() public {
        uint256 startingSupply = svm.createUint(64, "controller backing starting supply");
        uint256 startingBacking = svm.createUint(64, "controller backing starting backing");
        uint256 endingSupply = svm.createUint(64, "controller backing ending supply");

        vm.assume(startingSupply > 0);

        uint256 requiredEndingBacking = Math.mulDiv(startingBacking, endingSupply, startingSupply);
        if (mulmod(startingBacking, endingSupply, startingSupply) != 0) {
            unchecked {
                ++requiredEndingBacking;
            }
        }

        uint256[] memory start = _oneUint(startingBacking);
        uint256[] memory end = _oneUint(requiredEndingBacking);
        controller.exposedValidateBacking(startingSupply, start, endingSupply, end);

        if (requiredEndingBacking > 0) {
            end[0] = requiredEndingBacking - 1;
            (bool success, bytes memory returnData) = address(controller)
                .call(
                    abi.encodeCall(
                        ControllerHalmosHarness.exposedValidateBacking, (startingSupply, start, endingSupply, end)
                    )
                );

            assertFalse(success);
            assertEq(_revertSelector(returnData), IController.Controller__BackingWentDown.selector);
        }
    }

    function check_controllerExternalCallMintCannotReduceBacking() public {
        uint256 startingSupply = svm.createUint(64, "controller external starting supply");
        uint256 startingBacking = svm.createUint(64, "controller external starting backing");
        uint256 mintAmount = svm.createUint(64, "controller external mint amount");

        vm.assume(startingSupply > 0);
        vm.assume(startingBacking > 0);
        vm.assume(mintAmount > 0);

        _setAssetRegistry(ASSET);
        _setRedeemBacking(ASSET, startingBacking);
        token.setBalance(USER, startingSupply);

        IController.Settlement[] memory settlements = new IController.Settlement[](1);
        settlements[0] = _settlement(IController.StateTransitions.ExternalCall, 0, new IController.Receipt[](0));
        settlements[0].externalCalls = new IController.ExternalCall[](1);
        settlements[0].externalCalls[0] = IController.ExternalCall({
            target: address(token), data: abi.encodeCall(ControllerTokenMock.mint, (USER, mintAmount))
        });

        (bool success, bytes memory returnData) =
            address(module).call(abi.encodeCall(ControllerHalmosModule.settle, (settlements)));

        assertFalse(success);
        assertEq(_revertSelector(returnData), IController.Controller__BackingWentDown.selector);
        assertEq(token.totalSupply(), startingSupply);
        assertEq(token.balanceOf(USER), startingSupply);
        assertEq(uint256(kernel.viewData(Slots.slots(Slots.BACKING_AMOUNT_SLOT, ASSET))), startingBacking);
    }

    function testConcreteControllerPaymentSplitAndFeeRouting() public {
        uint256 receiptAmount = 400 ether;
        uint256 mintAmount = 273 ether;
        (IVault.TransferCall[] memory transferCalls, IVault.CreditCall[] memory creditCalls) =
            _assertPaymentSplitAndFeeRouting(receiptAmount, mintAmount, 1_000, 2_000);

        assertEq(transferCalls.length, 2);
        assertEq(creditCalls.length, 2);
        assertEq(token.totalSupply(), mintAmount);
    }

    function testConcreteControllerExternalCallMintCannotReduceBacking() public {
        uint256 startingSupply = 1_000 ether;
        uint256 startingBacking = 1_000 ether;
        uint256 mintAmount = 1 ether;

        _setAssetRegistry(ASSET);
        _setRedeemBacking(ASSET, startingBacking);
        token.setBalance(USER, startingSupply);

        IController.Settlement[] memory settlements = new IController.Settlement[](1);
        settlements[0] = _settlement(IController.StateTransitions.ExternalCall, 0, new IController.Receipt[](0));
        settlements[0].externalCalls = new IController.ExternalCall[](1);
        settlements[0].externalCalls[0] = IController.ExternalCall({
            target: address(token), data: abi.encodeCall(ControllerTokenMock.mint, (USER, mintAmount))
        });

        (bool success, bytes memory returnData) =
            address(module).call(abi.encodeCall(ControllerHalmosModule.settle, (settlements)));

        assertFalse(success);
        assertEq(_revertSelector(returnData), IController.Controller__BackingWentDown.selector);
        assertEq(token.totalSupply(), startingSupply);
    }

    function _settlement(IController.StateTransitions transition, uint256 amount, IController.Receipt[] memory receipts)
        internal
        pure
        returns (IController.Settlement memory settlement)
    {
        settlement = IController.Settlement({
            payer: USER,
            amount: amount,
            transition: transition,
            receipts: receipts,
            singleStateUpdates: new IController.StateUpdate[](0),
            multiStateUpdates: new IController.StateUpdates[](0),
            externalCalls: new IController.ExternalCall[](0)
        });
    }

    function _oneReceipt(address asset, uint256 amount) internal pure returns (IController.Receipt[] memory receipts) {
        receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: asset, amount: amount});
    }

    function _oneUint(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _setAssetRegistry(address asset) internal {
        kernel.setRaw(Slots.ASSETS_LENGTH_SLOT, bytes32(uint256(1)));
        kernel.setRaw(Slots.ASSETS_BASE_SLOT, bytes32(uint256(uint160(asset))));
    }

    function _setRedeemBacking(address asset, uint256 amount) internal {
        kernel.setRaw(Slots.slots(Slots.BACKING_AMOUNT_SLOT, asset), bytes32(amount));
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

    function _assertPaymentSplitAndFeeRouting(
        uint256 receiptAmount,
        uint256 mintAmount,
        uint256 teamBps,
        uint256 treasuryBps
    ) internal returns (IVault.TransferCall[] memory transferCalls, IVault.CreditCall[] memory creditCalls) {
        _setAssetRegistry(ASSET);
        kernel.setRaw(Slots.TEAM_PERCENTAGE_SLOT, bytes32(teamBps));
        kernel.setRaw(Slots.TREASURY_PERCENTAGE_SLOT, bytes32(treasuryBps));

        IController.Settlement memory payment =
            _settlement(IController.StateTransitions.Payment, mintAmount, _oneReceipt(ASSET, receiptAmount));
        (transferCalls, creditCalls) = controller.exposedDispatch(payment, module.KEYCODE());

        _assertPaymentTransfers(transferCalls, receiptAmount);
        _assertPaymentCredits(creditCalls, receiptAmount, teamBps, treasuryBps);
        assertEq(token.totalSupply(), mintAmount);
        assertEq(token.balanceOf(USER), mintAmount);
    }

    function _assertPaymentTransfers(IVault.TransferCall[] memory transferCalls, uint256 receiptAmount) internal pure {
        uint256 protocolFee = _mulDivUp(receiptAmount, AUCTION_FEE_BPS, BPS);

        _assertTransferCall(
            transferCalls[0],
            IVault.TransferType.Receive,
            IVault.Bucket.Treasury,
            IVault.Bucket.None,
            ASSET,
            USER,
            receiptAmount
        );
        _assertTransferCall(
            transferCalls[1],
            IVault.TransferType.Send,
            IVault.Bucket.None,
            IVault.Bucket.Treasury,
            ASSET,
            COLLECTOR,
            protocolFee
        );
    }

    function _assertPaymentCredits(
        IVault.CreditCall[] memory creditCalls,
        uint256 receiptAmount,
        uint256 teamBps,
        uint256 treasuryBps
    ) internal pure {
        uint256 netAmount = receiptAmount - _mulDivUp(receiptAmount, AUCTION_FEE_BPS, BPS);
        uint256 teamAmount = netAmount * teamBps / BPS;
        uint256 treasuryAmount = netAmount * treasuryBps / BPS;
        uint256 backingAmount = netAmount - teamAmount - treasuryAmount;

        _assertCreditCall(creditCalls[0], IVault.Bucket.Treasury, IVault.Bucket.Redeem, ASSET, backingAmount);
        _assertCreditCall(creditCalls[1], IVault.Bucket.Treasury, IVault.Bucket.Team, ASSET, teamAmount);
        assertLe(backingAmount + teamAmount + treasuryAmount, netAmount);
    }

    function _assertTransferCall(
        IVault.TransferCall memory call,
        IVault.TransferType callType,
        IVault.Bucket toBucket,
        IVault.Bucket fromBucket,
        address asset,
        address user,
        uint256 amount
    ) internal pure {
        assertEq(uint256(call.callType), uint256(callType));
        assertEq(uint256(call.toBucket), uint256(toBucket));
        assertEq(uint256(call.fromBucket), uint256(fromBucket));
        assertEq(call.asset, asset);
        assertEq(call.user, user);
        assertEq(call.amount, amount);
    }

    function _assertCreditCall(
        IVault.CreditCall memory call,
        IVault.Bucket from,
        IVault.Bucket to,
        address asset,
        uint256 amount
    ) internal pure {
        assertEq(uint256(call.from), uint256(from));
        assertEq(uint256(call.to), uint256(to));
        assertEq(call.asset, asset);
        assertEq(call.amount, amount);
    }

    function _revertSelector(bytes memory returnData) internal pure returns (bytes4 selector) {
        assert(returnData.length >= 4);
        assembly ("memory-safe") {
            selector := mload(add(returnData, 0x20))
        }
    }
}
