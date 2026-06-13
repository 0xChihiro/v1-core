///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Controller} from "../src/Controller.sol";
import {Kernel} from "../src/Kernel.sol";
import {Module} from "../src/Module.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";
import {IController} from "../src/interfaces/IController.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {Slots} from "../src/libraries/Slots.sol";
import {Actions, Keycode} from "../src/Utils.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract BackingInvariantModule is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("BINVR"));
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    function settle(IController.Settlement[] calldata settlements) external {
        CONTROLLER.settle(settlements);
    }
}

contract BackingInvariantHandler is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant AUCTION_FEE_BPS = 250;
    uint256 internal constant MAX_STEP = 25 ether;

    Controller public immutable controller;
    Kernel public immutable kernel;
    Vault public immutable vault;
    Token public immutable token;
    BackingInvariantModule public immutable module;
    ERC20Mock public immutable asset;
    ERC20Mock public immutable secondAsset;
    address public immutable user;

    uint256 public successfulSettlements;
    uint256 public rejectedSettlements;

    constructor(
        Controller controller_,
        Kernel kernel_,
        Vault vault_,
        Token token_,
        BackingInvariantModule module_,
        ERC20Mock asset_,
        ERC20Mock secondAsset_,
        address user_
    ) {
        controller = controller_;
        kernel = kernel_;
        vault = vault_;
        token = token_;
        module = module_;
        asset = asset_;
        secondAsset = secondAsset_;
        user = user_;
    }

    function safePayment(uint256 seed) external {
        uint256 mintAmount = _amount(seed);
        IController.Receipt[] memory receipts = new IController.Receipt[](2);
        receipts[0] = IController.Receipt({asset: address(asset), amount: _receiptForNetBacking(mintAmount)});
        receipts[1] = IController.Receipt({asset: address(secondAsset), amount: _receiptForNetBacking(mintAmount)});

        _mintAndApprove(receipts[0].amount, receipts[1].amount);
        _attempt(_singleSettlement(IController.StateTransitions.Payment, mintAmount, receipts));
    }

    function underBackedPayment(uint256 seed) external {
        uint256 mintAmount = _amount(seed);
        IController.Receipt[] memory receipts = new IController.Receipt[](2);
        receipts[0] = IController.Receipt({asset: address(asset), amount: mintAmount / 2});
        receipts[1] = IController.Receipt({asset: address(secondAsset), amount: mintAmount / 2});

        _mintAndApprove(receipts[0].amount, receipts[1].amount);
        _attempt(_singleSettlement(IController.StateTransitions.Payment, mintAmount, receipts));
    }

    function oneSidedPayment(uint256 seed) external {
        uint256 mintAmount = _amount(seed);
        IController.Receipt[] memory receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: address(asset), amount: _receiptForNetBacking(mintAmount)});

        _mintAndApprove(receipts[0].amount, 0);
        _attempt(_singleSettlement(IController.StateTransitions.Payment, mintAmount, receipts));
    }

    function safeRedeem(uint256 seed) external {
        uint256 burnAmount = _burnAmount(seed);
        if (burnAmount == 0) return;

        IController.Receipt[] memory receipts = new IController.Receipt[](2);
        receipts[0] = IController.Receipt({asset: address(asset), amount: _maxSafeRedeem(address(asset), burnAmount)});
        receipts[1] = IController.Receipt({
            asset: address(secondAsset), amount: _maxSafeRedeem(address(secondAsset), burnAmount)
        });

        _attempt(_singleSettlement(IController.StateTransitions.Redeem, burnAmount, receipts));
    }

    function overRedeem(uint256 seed) external {
        uint256 burnAmount = _burnAmount(seed);
        if (burnAmount == 0) return;

        IController.Receipt[] memory receipts = new IController.Receipt[](2);
        receipts[0] =
            IController.Receipt({asset: address(asset), amount: _maxSafeRedeem(address(asset), burnAmount) + 1});
        receipts[1] = IController.Receipt({
            asset: address(secondAsset), amount: _maxSafeRedeem(address(secondAsset), burnAmount)
        });

        _attempt(_singleSettlement(IController.StateTransitions.Redeem, burnAmount, receipts));
    }

    function borrowAndRepay(uint256 seed) external {
        address selectedAsset = seed & 1 == 0 ? address(asset) : address(secondAsset);
        uint256 redeem = _bucketValue(IVault.Bucket.Redeem, selectedAsset);
        if (redeem == 0) return;

        uint256 borrowAmount = bound(seed >> 1, 1, _min(redeem, MAX_STEP));
        _attempt(_singleSettlement(IController.StateTransitions.Borrow, 0, _oneReceipt(selectedAsset, borrowAmount)));

        uint256 borrowed = _bucketValue(IVault.Bucket.Borrow, selectedAsset);
        if (borrowed == 0) return;

        uint256 repayAmount = _min(borrowAmount, borrowed);
        if (selectedAsset == address(asset)) {
            vm.prank(user);
            asset.approve(address(vault), repayAmount);
        } else {
            vm.prank(user);
            secondAsset.approve(address(vault), repayAmount);
        }
        _attempt(_singleSettlement(IController.StateTransitions.Repay, 0, _oneReceipt(selectedAsset, repayAmount)));
    }

    function safeStateMoveRedeemToBorrow(uint256 seed) external {
        address selectedAsset = seed & 1 == 0 ? address(asset) : address(secondAsset);
        uint256 redeem = _bucketValue(IVault.Bucket.Redeem, selectedAsset);
        if (redeem == 0) return;

        uint256 amount = bound(seed >> 1, 1, _min(redeem, MAX_STEP));
        IController.StateUpdate[] memory updates = new IController.StateUpdate[](2);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Sub, slot: _bucketSlot(IVault.Bucket.Redeem, selectedAsset), data: bytes32(amount)
        });
        updates[1] = IController.StateUpdate({
            op: IController.Op.Add, slot: _bucketSlot(IVault.Bucket.Borrow, selectedAsset), data: bytes32(amount)
        });

        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        settlements[0].singleStateUpdates = updates;
        _attempt(settlements);
    }

    function unsafeStateDecrease(uint256 seed) external {
        address selectedAsset = seed & 1 == 0 ? address(asset) : address(secondAsset);
        uint256 redeem = _bucketValue(IVault.Bucket.Redeem, selectedAsset);
        if (redeem == 0) return;

        uint256 amount = bound(seed >> 1, 1, _min(redeem, MAX_STEP));
        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        settlements[0].singleStateUpdates =
            _oneStateUpdate(IController.Op.Sub, _bucketSlot(IVault.Bucket.Redeem, selectedAsset), bytes32(amount));
        _attempt(settlements);
    }

    function removeStartingAssetThenDecrease(uint256 seed) external {
        address selectedAsset = seed & 1 == 0 ? address(asset) : address(secondAsset);
        uint256 redeem = _bucketValue(IVault.Bucket.Redeem, selectedAsset);
        if (redeem == 0) return;

        IController.StateUpdate[] memory updates = new IController.StateUpdate[](2);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Set, slot: Slots.ASSETS_LENGTH_SLOT, data: bytes32(uint256(1))
        });
        updates[1] = IController.StateUpdate({
            op: IController.Op.Sub, slot: _bucketSlot(IVault.Bucket.Redeem, selectedAsset), data: bytes32(uint256(1))
        });

        IController.StateUpdates[] memory multiUpdates = new IController.StateUpdates[](1);
        address remainingAsset = selectedAsset == address(asset) ? address(secondAsset) : address(asset);
        multiUpdates[0] = IController.StateUpdates({
            startSlot: Slots.ASSETS_BASE_SLOT, data: abi.encodePacked(bytes32(uint256(uint160(remainingAsset))))
        });

        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        settlements[0].singleStateUpdates = updates;
        settlements[0].multiStateUpdates = multiUpdates;
        _attempt(settlements);
    }

    function batchTemporaryDecreaseThenRestore(uint256 seed) external {
        address selectedAsset = seed & 1 == 0 ? address(asset) : address(secondAsset);
        uint256 redeem = _bucketValue(IVault.Bucket.Redeem, selectedAsset);
        if (redeem == 0) return;

        uint256 amount = bound(seed >> 1, 1, _min(redeem, MAX_STEP));
        IController.Settlement[] memory settlements = new IController.Settlement[](2);
        settlements[0] = _settlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        settlements[0].singleStateUpdates =
            _oneStateUpdate(IController.Op.Sub, _bucketSlot(IVault.Bucket.Redeem, selectedAsset), bytes32(amount));
        settlements[1] = _settlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        settlements[1].singleStateUpdates =
            _oneStateUpdate(IController.Op.Add, _bucketSlot(IVault.Bucket.Redeem, selectedAsset), bytes32(amount));

        _attempt(settlements);
    }

    function _attempt(IController.Settlement[] memory settlements) internal {
        uint256 beforeAssetBacking = backingOf(address(asset));
        uint256 beforeSecondAssetBacking = backingOf(address(secondAsset));
        uint256 beforeSupply = token.totalSupply();

        try module.settle(settlements) {
            ++successfulSettlements;
            _assertBackingDidNotDecrease(beforeSupply, beforeAssetBacking, address(asset));
            _assertBackingDidNotDecrease(beforeSupply, beforeSecondAssetBacking, address(secondAsset));
        } catch {
            ++rejectedSettlements;
        }
    }

    function _assertBackingDidNotDecrease(uint256 beforeSupply, uint256 beforeBacking, address backingAsset)
        internal
        view
    {
        if (beforeSupply == 0) return;
        uint256 afterSupply = token.totalSupply();
        uint256 afterBacking = backingOf(backingAsset);
        assertGe(afterBacking * beforeSupply, beforeBacking * afterSupply, "unit backing decreased");
    }

    function backingOf(address backingAsset) public view returns (uint256) {
        return _bucketValue(IVault.Bucket.Redeem, backingAsset) + _bucketValue(IVault.Bucket.Borrow, backingAsset);
    }

    function hardAccountedHeldBuckets(address backingAsset) public view returns (uint256) {
        return _bucketValue(IVault.Bucket.Redeem, backingAsset) + _bucketValue(IVault.Bucket.Treasury, backingAsset)
            + _bucketValue(IVault.Bucket.Team, backingAsset) + _bucketValue(IVault.Bucket.Collateral, backingAsset);
    }

    function _maxSafeRedeem(address backingAsset, uint256 burnAmount) internal view returns (uint256) {
        uint256 supply = token.totalSupply();
        if (burnAmount >= supply) return 0;
        uint256 backing = backingOf(backingAsset);
        uint256 endingSupply = supply - burnAmount;
        uint256 requiredEndingBacking = _mulDivUp(backing, endingSupply, supply);
        return backing - requiredEndingBacking;
    }

    function _burnAmount(uint256 seed) internal view returns (uint256) {
        uint256 userBalance = token.balanceOf(user);
        if (userBalance <= 1) return 0;
        return bound(seed, 1, _min(userBalance - 1, MAX_STEP));
    }

    function _amount(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 1, MAX_STEP);
    }

    function _receiptForNetBacking(uint256 backingAmount) internal pure returns (uint256) {
        return _mulDivUp(backingAmount, BPS, BPS - AUCTION_FEE_BPS);
    }

    function _mintAndApprove(uint256 firstAmount, uint256 secondAmount) internal {
        if (firstAmount > 0) {
            asset.mint(user, firstAmount);
            vm.prank(user);
            asset.approve(address(vault), firstAmount);
        }
        if (secondAmount > 0) {
            secondAsset.mint(user, secondAmount);
            vm.prank(user);
            secondAsset.approve(address(vault), secondAmount);
        }
    }

    function _singleSettlement(
        IController.StateTransitions transition,
        uint256 amount,
        IController.Receipt[] memory receipts
    ) internal view returns (IController.Settlement[] memory settlements) {
        settlements = new IController.Settlement[](1);
        settlements[0] = _settlement(transition, amount, receipts);
    }

    function _settlement(IController.StateTransitions transition, uint256 amount, IController.Receipt[] memory receipts)
        internal
        view
        returns (IController.Settlement memory settlement)
    {
        settlement = IController.Settlement({
            payer: user,
            amount: amount,
            transition: transition,
            receipts: receipts,
            singleStateUpdates: new IController.StateUpdate[](0),
            multiStateUpdates: new IController.StateUpdates[](0),
            externalCalls: new IController.ExternalCall[](0)
        });
    }

    function _oneReceipt(address receiptAsset, uint256 amount)
        internal
        pure
        returns (IController.Receipt[] memory receipts)
    {
        receipts = new IController.Receipt[](1);
        receipts[0] = IController.Receipt({asset: receiptAsset, amount: amount});
    }

    function _oneStateUpdate(IController.Op op, bytes32 slot, bytes32 data)
        internal
        pure
        returns (IController.StateUpdate[] memory updates)
    {
        updates = new IController.StateUpdate[](1);
        updates[0] = IController.StateUpdate({op: op, slot: slot, data: data});
    }

    function _bucketValue(IVault.Bucket bucket, address token_) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, token_)));
    }

    function _bucketSlot(IVault.Bucket bucket, address token_) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, token_);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERAL_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
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

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract BackingInvariantTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;

    Controller controller;
    Kernel kernel;
    Vault vault;
    Token token;
    BackingInvariantModule module;
    BackingInvariantHandler handler;
    ERC20Mock asset;
    ERC20Mock secondAsset;

    address admin = makeAddr("Admin");
    address user = makeAddr("User");
    address protocolCollector = makeAddr("Protocol Collector");

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new Token("Enten", "ENTEN", predictedController, user, INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken, 0);

        module = new BackingInvariantModule(address(controller));
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();

        vm.startPrank(admin);
        controller.executeAction(Actions.InstallModule, address(module));
        controller.setMintPermission(module.KEYCODE(), true);
        vm.stopPrank();

        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, INITIAL_SUPPLY);

        handler = new BackingInvariantHandler(controller, kernel, vault, token, module, asset, secondAsset, user);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = BackingInvariantHandler.safePayment.selector;
        selectors[1] = BackingInvariantHandler.underBackedPayment.selector;
        selectors[2] = BackingInvariantHandler.oneSidedPayment.selector;
        selectors[3] = BackingInvariantHandler.safeRedeem.selector;
        selectors[4] = BackingInvariantHandler.overRedeem.selector;
        selectors[5] = BackingInvariantHandler.borrowAndRepay.selector;
        selectors[6] = BackingInvariantHandler.safeStateMoveRedeemToBorrow.selector;
        selectors[7] = BackingInvariantHandler.unsafeStateDecrease.selector;
        selectors[8] = BackingInvariantHandler.batchTemporaryDecreaseThenRestore.selector;

        excludeContract(address(controller));
        excludeContract(address(kernel));
        excludeContract(address(vault));
        excludeContract(address(token));
        excludeContract(address(asset));
        excludeContract(address(secondAsset));
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_unitBackingPerTokenNeverFallsBelowInitialRatio() public view {
        _assertBackingAtLeastInitialRatio(address(asset));
        _assertBackingAtLeastInitialRatio(address(secondAsset));
    }

    function invariant_vaultBalanceCoversHardAccountedHeldBuckets() public view {
        assertGe(
            asset.balanceOf(address(vault)), handler.hardAccountedHeldBuckets(address(asset)), "first asset custody"
        );
        assertGe(
            secondAsset.balanceOf(address(vault)),
            handler.hardAccountedHeldBuckets(address(secondAsset)),
            "second asset custody"
        );
    }

    function testHandlerExercisesBothAcceptedAndRejectedSettlements() public {
        handler.safePayment(1 ether);
        handler.underBackedPayment(1 ether);

        assertGt(handler.successfulSettlements(), 0, "no successful settlements exercised");
        assertGt(handler.rejectedSettlements(), 0, "no rejected settlements exercised");
    }

    function testRemovingAStartingAssetCannotBypassBackingCheck() public {
        handler.removeStartingAssetThenDecrease(0);

        assertEq(handler.successfulSettlements(), 0);
        assertEq(handler.rejectedSettlements(), 1);
        _assertBackingAtLeastInitialRatio(address(asset));
        _assertBackingAtLeastInitialRatio(address(secondAsset));
    }

    function _assertBackingAtLeastInitialRatio(address backingAsset) internal view {
        assertGe(handler.backingOf(backingAsset), token.totalSupply(), "backing below initial 1:1 ratio");
    }

    function _seedBacking(ERC20Mock token_, uint256 amount) internal {
        token_.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, address(token_), amount);
    }

    function _setAssets(address first, address second) internal {
        bytes memory data = abi.encodePacked(bytes32(uint256(uint160(first))), bytes32(uint256(uint160(second))));

        vm.startPrank(address(controller));
        kernel.updateState(Slots.ASSETS_LENGTH_SLOT, bytes32(uint256(2)));
        kernel.updateState(Slots.ASSETS_BASE_SLOT, data);
        vm.stopPrank();
    }

    function _setBucket(IVault.Bucket bucket, address token_, uint256 amount) internal {
        vm.prank(address(controller));
        kernel.updateState(_bucketSlot(bucket, token_), bytes32(amount));
    }

    function _bucketSlot(IVault.Bucket bucket, address token_) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, token_);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERAL_SLOT, token_);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token_) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token_));
    }
}
