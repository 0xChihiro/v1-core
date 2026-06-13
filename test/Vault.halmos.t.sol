///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vault} from "../src/Vault.sol";
import {IKernel} from "../src/interfaces/IKernel.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {Slots} from "../src/libraries/Slots.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";

contract VaultKernelMock is IKernel {
    address public immutable CONTROLLER;
    address public immutable VAULT;

    mapping(bytes32 => bytes32) internal data;

    constructor(address controller, address vault) {
        CONTROLLER = controller;
        VAULT = vault;
    }

    function accountingWriter() external view returns (address) {
        return VAULT;
    }

    function updateState(bytes32 startSlot, bytes calldata values) external {
        for (uint256 i; i < values.length; i += 32) {
            bytes32 value;
            assembly ("memory-safe") {
                value := calldataload(add(values.offset, i))
            }
            data[bytes32(uint256(startSlot) + (i / 32))] = value;
        }
    }

    function updateState(bytes32 slot, bytes32 value) external {
        data[slot] = value;
    }

    function updateState(KernelCall[] calldata calls) external {
        for (uint256 i; i < calls.length;) {
            data[calls[i].slot] = calls[i].data;
            unchecked {
                ++i;
            }
        }
    }

    function add(bytes32 slot, bytes32 value) public {
        data[slot] = bytes32(uint256(data[slot]) + uint256(value));
    }

    function add(KernelCall[] calldata calls) external {
        for (uint256 i; i < calls.length;) {
            add(calls[i].slot, calls[i].data);
            unchecked {
                ++i;
            }
        }
    }

    function sub(bytes32 slot, bytes32 value) public {
        data[slot] = bytes32(uint256(data[slot]) - uint256(value));
    }

    function sub(KernelCall[] calldata calls) external {
        for (uint256 i; i < calls.length;) {
            sub(calls[i].slot, calls[i].data);
            unchecked {
                ++i;
            }
        }
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

    function viewData(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length;) {
            values[i] = data[slots[i]];
            unchecked {
                ++i;
            }
        }
    }

    function viewData(bytes32 slot) external view returns (bytes32) {
        return data[slot];
    }
}

contract VaultHalmosTest is Test, SymTest {
    VaultKernelMock internal kernel;
    Vault internal vault;
    ERC20Mock internal asset;

    address internal constant CONTROLLER = address(0xC0117011e2);
    address internal constant USER = address(0xA11CE);

    function setUp() public {
        kernel = new VaultKernelMock(CONTROLLER, address(0));
        vault = new Vault(CONTROLLER, address(kernel));
        asset = new ERC20Mock();
    }

    function check_vaultCreditConservesCoreBucketSum() public {
        uint256 redeemStart = svm.createUint(64, "vault credit redeem start");
        uint256 treasuryStart = svm.createUint(64, "vault credit treasury start");
        uint256 teamStart = svm.createUint(64, "vault credit team start");
        uint256 amount = svm.createUint(64, "vault credit amount");
        IVault.Bucket from = _creditFromBucket(svm.createUint(8, "vault credit from"));
        IVault.Bucket to = _coreBucket(svm.createUint(8, "vault credit to"));

        _seedCoreBuckets(address(asset), redeemStart, treasuryStart, teamStart);
        vm.assume(amount <= _bucketValue(from, address(asset)));

        _assertCreditConservesCoreBucketSum(address(asset), amount, from, to);
    }

    function check_vaultCreditCannotUseRedeemAsSource() public {
        uint256 redeemStart = svm.createUint(64, "vault redeem source redeem start");
        uint256 treasuryStart = svm.createUint(64, "vault redeem source treasury start");
        uint256 teamStart = svm.createUint(64, "vault redeem source team start");
        uint256 amount = svm.createUint(64, "vault redeem source amount");
        IVault.Bucket to = _coreBucket(svm.createUint(8, "vault redeem source to"));

        _seedCoreBuckets(address(asset), redeemStart, treasuryStart, teamStart);
        _assertCreditCannotUseRedeemAsSource(address(asset), amount, to);
    }

    function check_vaultSendAccountingMovesBucketsAndTokens() public {
        uint256 sendAmount = svm.createUint(64, "vault send amount");
        uint256 redeemRemainder = svm.createUint(64, "vault send redeem remainder");
        uint256 borrowStart = svm.createUint(64, "vault send borrow start");

        _assertSendAccountingMovesBucketsAndTokens(sendAmount, redeemRemainder, borrowStart);
    }

    function check_vaultReceiveAccountingMovesTokensIntoBucket() public {
        uint256 receiveAmount = svm.createUint(64, "vault receive amount");
        uint256 redeemStart = svm.createUint(64, "vault receive redeem start");

        _assertReceiveAccountingMovesTokensIntoBucket(receiveAmount, redeemStart);
    }

    function check_vaultRejectsNoneBucketForReceive() public {
        _assertRejectsNoneBucketForReceive();
    }

    function check_vaultRejectsNoneBucketForSend() public {
        _assertRejectsNoneBucketForSend();
    }

    function testConcreteVaultCreditConservesCoreBucketSum() public {
        address backingAsset = address(0xBEEF);
        _seedCoreBuckets(backingAsset, 100, 200, 300);
        _assertCreditConservesCoreBucketSum(backingAsset, 75, IVault.Bucket.Treasury, IVault.Bucket.Redeem);
    }

    function testConcreteVaultCreditCannotUseRedeemAsSource() public {
        address backingAsset = address(0xBEEF);
        _seedCoreBuckets(backingAsset, 100, 200, 300);
        _assertCreditCannotUseRedeemAsSource(backingAsset, 75, IVault.Bucket.Team);
    }

    function testConcreteVaultSendAccountingMovesBucketsAndTokens() public {
        _assertSendAccountingMovesBucketsAndTokens(25, 75, 10);
    }

    function testConcreteVaultReceiveAccountingMovesTokensIntoBucket() public {
        _assertReceiveAccountingMovesTokensIntoBucket(25, 75);
    }

    function testConcreteVaultRejectsNoneBucketForReceive() public {
        _assertRejectsNoneBucketForReceive();
    }

    function testConcreteVaultRejectsNoneBucketForSend() public {
        _assertRejectsNoneBucketForSend();
    }

    function _assertCreditConservesCoreBucketSum(
        address backingAsset,
        uint256 amount,
        IVault.Bucket from,
        IVault.Bucket to
    ) internal {
        uint256 redeemBefore = _bucketValue(IVault.Bucket.Redeem, backingAsset);
        uint256 treasuryBefore = _bucketValue(IVault.Bucket.Treasury, backingAsset);
        uint256 teamBefore = _bucketValue(IVault.Bucket.Team, backingAsset);
        uint256 beforeSum = redeemBefore + treasuryBefore + teamBefore;

        vm.prank(CONTROLLER);
        vault.credit(backingAsset, amount, from, to);

        uint256 afterSum = _bucketValue(IVault.Bucket.Redeem, backingAsset)
            + _bucketValue(IVault.Bucket.Treasury, backingAsset) + _bucketValue(IVault.Bucket.Team, backingAsset);
        assertEq(afterSum, beforeSum);
        assertEq(_bucketValue(IVault.Bucket.Borrow, backingAsset), 0);
        assertEq(_bucketValue(IVault.Bucket.Collateral, backingAsset), 0);
    }

    function _assertCreditCannotUseRedeemAsSource(address backingAsset, uint256 amount, IVault.Bucket to) internal {
        uint256 redeemBefore = _bucketValue(IVault.Bucket.Redeem, backingAsset);
        uint256 treasuryBefore = _bucketValue(IVault.Bucket.Treasury, backingAsset);
        uint256 teamBefore = _bucketValue(IVault.Bucket.Team, backingAsset);

        vm.prank(CONTROLLER);
        (bool success, bytes memory returnData) =
            address(vault).call(abi.encodeCall(Vault.credit, (backingAsset, amount, IVault.Bucket.Redeem, to)));

        assertFalse(success);
        assertEq(_revertSelector(returnData), Vault.Vault__CannotLowerBacking.selector);
        assertEq(_bucketValue(IVault.Bucket.Redeem, backingAsset), redeemBefore);
        assertEq(_bucketValue(IVault.Bucket.Treasury, backingAsset), treasuryBefore);
        assertEq(_bucketValue(IVault.Bucket.Team, backingAsset), teamBefore);
    }

    function _assertSendAccountingMovesBucketsAndTokens(
        uint256 sendAmount,
        uint256 redeemRemainder,
        uint256 borrowStart
    ) internal {
        uint256 startingRedeem = sendAmount + redeemRemainder;
        asset.mint(address(vault), startingRedeem);
        _setBucket(IVault.Bucket.Redeem, address(asset), startingRedeem);
        _setBucket(IVault.Bucket.Borrow, address(asset), borrowStart);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.Borrow,
            fromBucket: IVault.Bucket.Redeem,
            asset: address(asset),
            user: USER,
            amount: sendAmount
        });

        vm.prank(CONTROLLER);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), redeemRemainder);
        assertEq(asset.balanceOf(USER), sendAmount);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), redeemRemainder);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), borrowStart + sendAmount);
    }

    function _assertReceiveAccountingMovesTokensIntoBucket(uint256 receiveAmount, uint256 redeemStart) internal {
        asset.mint(USER, receiveAmount);
        vm.prank(USER);
        asset.approve(address(vault), receiveAmount);

        _setBucket(IVault.Bucket.Redeem, address(asset), redeemStart);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Redeem,
            fromBucket: IVault.Bucket.None,
            asset: address(asset),
            user: USER,
            amount: receiveAmount
        });

        vm.prank(CONTROLLER);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), receiveAmount);
        assertEq(asset.balanceOf(USER), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), redeemStart + receiveAmount);
    }

    function _assertRejectsNoneBucketForReceive() internal {
        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.None,
            asset: address(asset),
            user: USER,
            amount: 0
        });

        vm.prank(CONTROLLER);
        (bool success, bytes memory returnData) = address(vault).call(abi.encodeCall(Vault.handleAccounting, (calls)));

        assertFalse(success);
        assertEq(_revertSelector(returnData), Vault.Vault__InvalidBucket.selector);
    }

    function _assertRejectsNoneBucketForSend() internal {
        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.None,
            asset: address(asset),
            user: USER,
            amount: 0
        });

        vm.prank(CONTROLLER);
        (bool success, bytes memory returnData) = address(vault).call(abi.encodeCall(Vault.handleAccounting, (calls)));

        assertFalse(success);
        assertEq(_revertSelector(returnData), Vault.Vault__InvalidBucket.selector);
    }

    function _seedCoreBuckets(address backingAsset, uint256 redeemStart, uint256 treasuryStart, uint256 teamStart)
        internal
    {
        _setBucket(IVault.Bucket.Redeem, backingAsset, redeemStart);
        _setBucket(IVault.Bucket.Treasury, backingAsset, treasuryStart);
        _setBucket(IVault.Bucket.Team, backingAsset, teamStart);
    }

    function _setBucket(IVault.Bucket bucket, address backingAsset, uint256 amount) internal {
        vm.prank(CONTROLLER);
        kernel.updateState(_bucketSlot(bucket, backingAsset), bytes32(amount));
    }

    function _bucketValue(IVault.Bucket bucket, address backingAsset) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, backingAsset)));
    }

    function _creditFromBucket(uint256 seed) internal pure returns (IVault.Bucket) {
        return seed & 1 == 0 ? IVault.Bucket.Treasury : IVault.Bucket.Team;
    }

    function _coreBucket(uint256 seed) internal pure returns (IVault.Bucket) {
        uint256 selected = seed % 3;
        if (selected == 0) return IVault.Bucket.Redeem;
        if (selected == 1) return IVault.Bucket.Treasury;
        return IVault.Bucket.Team;
    }

    function _bucketSlot(IVault.Bucket bucket, address backingAsset) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, backingAsset);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, backingAsset);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, backingAsset);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, backingAsset);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERAL_SLOT, backingAsset);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address backingAsset) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, backingAsset));
    }

    function _revertSelector(bytes memory returnData) internal pure returns (bytes4 selector) {
        assert(returnData.length >= 4);
        assembly ("memory-safe") {
            selector := mload(add(returnData, 0x20))
        }
    }
}
