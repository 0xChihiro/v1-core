///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Kernel} from "../src/Kernel.sol";
import {Vault} from "../src/Vault.sol";
import {IKernel} from "../src/interfaces/IKernel.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {Slots} from "../src/libraries/Slots.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract VaultSlotHarness is Vault {
    constructor(address controller, address kernel) Vault(controller, kernel) {}

    function exposedBucketSlot(IVault.Bucket bucket, address token) external pure returns (bytes32) {
        return _bucketSlot(bucket, token);
    }
}

contract VaultTest is Test {
    uint256 internal constant MAX_FUZZ_TRANSFER_COUNT = 16;
    uint256 internal constant MAX_FUZZ_TRANSFER_AMOUNT = 1e18;

    Kernel kernel;
    Vault vault;
    VaultSlotHarness slotHarness;
    ERC20Mock asset;
    ERC20Mock secondAsset;

    address controller = makeAddr("Controller");
    address user = makeAddr("User");
    address collector = makeAddr("Collector");

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);

        kernel = new Kernel(controller, predictedVault);
        vault = new Vault(controller, predictedKernel);
        slotHarness = new VaultSlotHarness(controller, predictedKernel);

        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();
    }

    function testConstructorSetsImmutableAddressesAndRejectsZero() public {
        vm.expectRevert(Vault.Vault__MisconfiguredSetup.selector);
        new Vault(address(0), address(kernel));

        vm.expectRevert(Vault.Vault__MisconfiguredSetup.selector);
        new Vault(controller, address(0));

        assertEq(vault.CONTROLLER(), controller);
        assertEq(address(vault.KERNEL()), address(kernel));
    }

    function testBucketSlotDerivationMapsValidBucketsAndRejectsInvalidBucket() public {
        assertEq(
            slotHarness.exposedBucketSlot(IVault.Bucket.Borrow, address(asset)),
            _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, address(asset))
        );
        assertEq(
            slotHarness.exposedBucketSlot(IVault.Bucket.Redeem, address(asset)),
            _slot(Slots.BACKING_AMOUNT_SLOT, address(asset))
        );
        assertEq(
            slotHarness.exposedBucketSlot(IVault.Bucket.Treasury, address(asset)),
            _slot(Slots.TREASURY_AMOUNT_SLOT, address(asset))
        );
        assertEq(
            slotHarness.exposedBucketSlot(IVault.Bucket.Team, address(asset)),
            _slot(Slots.TEAM_AMOUNT_SLOT, address(asset))
        );
        assertEq(
            slotHarness.exposedBucketSlot(IVault.Bucket.Collateral, address(asset)),
            _slot(Slots.TOTAL_COLLATERL_SLOT, address(asset))
        );

        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        slotHarness.exposedBucketSlot(IVault.Bucket.None, address(asset));
    }

    function testOnlyControllerCanMutate() public {
        IVault.TransferCall[] memory transferCalls = new IVault.TransferCall[](0);

        vm.expectRevert(Vault.Vault__OnlyController.selector);
        vault.handleAccounting(transferCalls);

        vm.expectRevert(Vault.Vault__OnlyController.selector);
        vault.credit(address(asset), 1, IVault.Bucket.Treasury, IVault.Bucket.Team);

        IVault.CreditCall[] memory creditCalls = new IVault.CreditCall[](0);
        vm.expectRevert(Vault.Vault__OnlyController.selector);
        vault.credits(creditCalls);

        vm.expectRevert(Vault.Vault__OnlyController.selector);
        vault.syncSurplus(address(asset), IVault.Bucket.Redeem);
    }

    function testEmptyAccountingAndCreditBatchesLeaveStateUnchanged() public {
        asset.mint(address(vault), 125);
        asset.mint(user, 55);
        secondAsset.mint(address(vault), 30);
        _setBucket(IVault.Bucket.Borrow, address(asset), 10);
        _setBucket(IVault.Bucket.Redeem, address(asset), 20);
        _setBucket(IVault.Bucket.Treasury, address(asset), 30);
        _setBucket(IVault.Bucket.Team, address(asset), 40);
        _setBucket(IVault.Bucket.Collateral, address(secondAsset), 50);

        IVault.TransferCall[] memory transferCalls = new IVault.TransferCall[](0);
        IVault.CreditCall[] memory creditCalls = new IVault.CreditCall[](0);

        vm.startPrank(controller);
        vault.handleAccounting(transferCalls);
        vault.credits(creditCalls);
        vm.stopPrank();

        assertEq(asset.balanceOf(address(vault)), 125);
        assertEq(asset.balanceOf(user), 55);
        assertEq(secondAsset.balanceOf(address(vault)), 30);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 10);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 20);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 30);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 40);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(secondAsset)), 50);
    }

    function testHandleAccountingBorrowMovesRedeemToBorrowAndSendsTokens() public {
        asset.mint(address(vault), 100);
        _setBucket(IVault.Bucket.Redeem, address(asset), 100);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.Borrow,
            fromBucket: IVault.Bucket.Redeem,
            asset: address(asset),
            user: user,
            amount: 40
        });

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 60);
        assertEq(asset.balanceOf(user), 40);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 60);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40);
    }

    function testHandleAccountingRepayMovesBorrowToRedeemAndReceivesTokens() public {
        asset.mint(user, 40);
        _setBucket(IVault.Bucket.Borrow, address(asset), 40);

        vm.prank(user);
        asset.approve(address(vault), 40);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Redeem,
            fromBucket: IVault.Bucket.Borrow,
            asset: address(asset),
            user: user,
            amount: 40
        });

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 40);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 40);
    }

    function testHandleAccountingRedeemSendsTokensFromRedeem() public {
        asset.mint(address(vault), 80);
        _setBucket(IVault.Bucket.Redeem, address(asset), 80);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.Redeem,
            asset: address(asset),
            user: user,
            amount: 30
        });

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 50);
        assertEq(asset.balanceOf(user), 30);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 50);
    }

    function testHandleAccountingPaymentReceivesIntoTreasuryAndSendsFee() public {
        asset.mint(user, 100);

        vm.prank(user);
        asset.approve(address(vault), 100);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](2);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Treasury,
            fromBucket: IVault.Bucket.None,
            asset: address(asset),
            user: user,
            amount: 100
        });
        calls[1] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.Treasury,
            asset: address(asset),
            user: collector,
            amount: 3
        });

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 97);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(collector), 3);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 97);
    }

    function testHandleAccountingDeploySendsTokensFromTreasury() public {
        asset.mint(address(vault), 70);
        _setBucket(IVault.Bucket.Treasury, address(asset), 70);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.Treasury,
            asset: address(asset),
            user: user,
            amount: 25
        });

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 45);
        assertEq(asset.balanceOf(user), 25);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 45);
    }

    function testHandleAccountingRecallReceivesTokensIntoTreasury() public {
        asset.mint(user, 40);

        vm.prank(user);
        asset.approve(address(vault), 40);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Treasury,
            fromBucket: IVault.Bucket.None,
            asset: address(asset),
            user: user,
            amount: 40
        });

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 40);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 40);
    }

    function testHandleAccountingClaimSendsTokensFromTeam() public {
        asset.mint(address(vault), 50);
        _setBucket(IVault.Bucket.Team, address(asset), 50);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.Team,
            asset: address(asset),
            user: user,
            amount: 20
        });

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 30);
        assertEq(asset.balanceOf(user), 20);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 30);
    }

    function testHandleAccountingDepositSendsBackingAndReceivesCollateral() public {
        asset.mint(address(vault), 100);
        secondAsset.mint(user, 25);
        _setBucket(IVault.Bucket.Redeem, address(asset), 100);

        vm.prank(user);
        secondAsset.approve(address(vault), 25);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](2);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.Borrow,
            fromBucket: IVault.Bucket.Redeem,
            asset: address(asset),
            user: user,
            amount: 45
        });
        calls[1] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Collateral,
            fromBucket: IVault.Bucket.None,
            asset: address(secondAsset),
            user: user,
            amount: 25
        });

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 55);
        assertEq(asset.balanceOf(user), 45);
        assertEq(secondAsset.balanceOf(address(vault)), 25);
        assertEq(secondAsset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 55);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 45);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(secondAsset)), 25);
    }

    function testHandleAccountingWithdrawReceivesBackingAndSendsCollateral() public {
        asset.mint(user, 45);
        secondAsset.mint(address(vault), 25);
        _setBucket(IVault.Bucket.Borrow, address(asset), 45);
        _setBucket(IVault.Bucket.Collateral, address(secondAsset), 25);

        vm.prank(user);
        asset.approve(address(vault), 45);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](2);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Redeem,
            fromBucket: IVault.Bucket.Borrow,
            asset: address(asset),
            user: user,
            amount: 45
        });
        calls[1] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.Collateral,
            asset: address(secondAsset),
            user: user,
            amount: 25
        });

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 45);
        assertEq(asset.balanceOf(user), 0);
        assertEq(secondAsset.balanceOf(address(vault)), 0);
        assertEq(secondAsset.balanceOf(user), 25);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 45);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(secondAsset)), 0);
    }

    function testFuzzHandleAccountingArrayMatchesBucketAndTokenBalanceModel(
        uint8 rawLength,
        uint8[16] memory rawKinds,
        uint96[16] memory rawAmounts
    ) public {
        uint256 length = bound(uint256(rawLength), 0, MAX_FUZZ_TRANSFER_COUNT);
        uint256 initialBucketBalance = MAX_FUZZ_TRANSFER_COUNT * MAX_FUZZ_TRANSFER_AMOUNT;
        uint256 expectedVaultBalance = initialBucketBalance * 4;
        uint256 expectedUserBalance = initialBucketBalance;
        uint256[5] memory expectedBuckets;

        for (uint256 i; i < expectedBuckets.length;) {
            expectedBuckets[i] = initialBucketBalance;
            unchecked {
                ++i;
            }
        }

        _setBucket(IVault.Bucket.Borrow, address(asset), initialBucketBalance);
        _setBucket(IVault.Bucket.Redeem, address(asset), initialBucketBalance);
        _setBucket(IVault.Bucket.Treasury, address(asset), initialBucketBalance);
        _setBucket(IVault.Bucket.Team, address(asset), initialBucketBalance);
        _setBucket(IVault.Bucket.Collateral, address(asset), initialBucketBalance);

        asset.mint(address(vault), expectedVaultBalance);
        asset.mint(user, expectedUserBalance);

        vm.prank(user);
        asset.approve(address(vault), expectedUserBalance);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](length);
        for (uint256 i; i < length;) {
            (IVault.TransferType callType, IVault.Bucket toBucket, IVault.Bucket fromBucket) =
                _fuzzTransferShape(rawKinds[i]);
            uint256 amount = bound(uint256(rawAmounts[i]), 0, MAX_FUZZ_TRANSFER_AMOUNT);

            calls[i] = IVault.TransferCall({
                callType: callType,
                toBucket: toBucket,
                fromBucket: fromBucket,
                asset: address(asset),
                user: user,
                amount: amount
            });

            if (fromBucket != IVault.Bucket.None) {
                expectedBuckets[_bucketIndex(fromBucket)] -= amount;
            }
            if (toBucket != IVault.Bucket.None) {
                expectedBuckets[_bucketIndex(toBucket)] += amount;
            }

            if (callType == IVault.TransferType.Receive) {
                expectedVaultBalance += amount;
                expectedUserBalance -= amount;
            } else {
                expectedVaultBalance -= amount;
                expectedUserBalance += amount;
            }

            unchecked {
                ++i;
            }
        }

        vm.prank(controller);
        vault.handleAccounting(calls);

        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), expectedBuckets[0]);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), expectedBuckets[1]);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), expectedBuckets[2]);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), expectedBuckets[3]);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(asset)), expectedBuckets[4]);
        assertEq(asset.balanceOf(address(vault)), expectedVaultBalance);
        assertEq(asset.balanceOf(user), expectedUserBalance);
        assertEq(
            asset.balanceOf(address(vault)),
            expectedBuckets[1] + expectedBuckets[2] + expectedBuckets[3] + expectedBuckets[4]
        );
    }

    function testHandleAccountingRejectsReceiveToNoneBucket() public {
        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.Borrow,
            asset: address(asset),
            user: user,
            amount: 1
        });

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.handleAccounting(calls);
    }

    function testHandleAccountingRejectsSendFromNoneBucket() public {
        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.Borrow,
            fromBucket: IVault.Bucket.None,
            asset: address(asset),
            user: user,
            amount: 1
        });

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.handleAccounting(calls);
    }

    function testHandleAccountingRejectsInvalidTransferType() public {
        bytes memory data = abi.encodeWithSelector(
            Vault.handleAccounting.selector,
            uint256(0x20),
            uint256(1),
            uint256(2),
            uint256(uint8(IVault.Bucket.Redeem)),
            uint256(uint8(IVault.Bucket.None)),
            address(asset),
            user,
            uint256(1)
        );

        vm.prank(controller);
        (bool success,) = address(vault).call(data);

        assertFalse(success);
    }

    function testHandleAccountingRevertsAtomicallyWhenTokenTransferFails() public {
        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Treasury,
            fromBucket: IVault.Bucket.None,
            asset: address(asset),
            user: user,
            amount: 10
        });

        vm.prank(controller);
        vm.expectRevert();
        vault.handleAccounting(calls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function testHandleAccountingRevertsAtomicallyWhenAccountingSubFails() public {
        asset.mint(address(vault), 100);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](1);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.Borrow,
            fromBucket: IVault.Bucket.Redeem,
            asset: address(asset),
            user: user,
            amount: 10
        });

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 100);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 0);
    }

    function testHandleAccountingBatchRevertsAtomicallyWhenLaterSubFails() public {
        asset.mint(user, 20);

        vm.prank(user);
        asset.approve(address(vault), 20);

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](2);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Treasury,
            fromBucket: IVault.Bucket.None,
            asset: address(asset),
            user: user,
            amount: 20
        });
        calls[1] = IVault.TransferCall({
            callType: IVault.TransferType.Send,
            toBucket: IVault.Bucket.None,
            fromBucket: IVault.Bucket.Redeem,
            asset: address(asset),
            user: user,
            amount: 1
        });

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(user), 20);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 0);
    }

    function testHandleAccountingBatchRevertsAtomicallyWhenLaterTokenTransferFails() public {
        asset.mint(user, 5);

        vm.startPrank(user);
        asset.approve(address(vault), 5);
        secondAsset.approve(address(vault), 10);
        vm.stopPrank();

        IVault.TransferCall[] memory calls = new IVault.TransferCall[](2);
        calls[0] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Treasury,
            fromBucket: IVault.Bucket.None,
            asset: address(asset),
            user: user,
            amount: 5
        });
        calls[1] = IVault.TransferCall({
            callType: IVault.TransferType.Receive,
            toBucket: IVault.Bucket.Team,
            fromBucket: IVault.Bucket.None,
            asset: address(secondAsset),
            user: user,
            amount: 10
        });

        vm.prank(controller);
        vm.expectRevert();
        vault.handleAccounting(calls);

        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(user), 5);
        assertEq(secondAsset.balanceOf(address(vault)), 0);
        assertEq(secondAsset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Team, address(secondAsset)), 0);
    }

    function testCreditMovesBetweenCoreBuckets() public {
        _setBucket(IVault.Bucket.Treasury, address(asset), 100);

        vm.prank(controller);
        vault.credit(address(asset), 35, IVault.Bucket.Treasury, IVault.Bucket.Team);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 65);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 35);
    }

    function testCreditAndCreditsMoveAccountingWithoutMovingErc20Balances() public {
        asset.mint(address(vault), 123);
        asset.mint(user, 456);
        _setBucket(IVault.Bucket.Treasury, address(asset), 80);
        _setBucket(IVault.Bucket.Team, address(asset), 40);

        vm.prank(controller);
        vault.credit(address(asset), 15, IVault.Bucket.Treasury, IVault.Bucket.Team);

        assertEq(asset.balanceOf(address(vault)), 123);
        assertEq(asset.balanceOf(user), 456);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 65);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 55);

        IVault.CreditCall[] memory calls = new IVault.CreditCall[](2);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Team, to: IVault.Bucket.Treasury, asset: address(asset), amount: 10
        });
        calls[1] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Redeem, asset: address(asset), amount: 20
        });

        vm.prank(controller);
        vault.credits(calls);

        assertEq(asset.balanceOf(address(vault)), 123);
        assertEq(asset.balanceOf(user), 456);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 55);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 45);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 20);
    }

    function testCreditRejectsRedeemSourceAndNonCoreBuckets() public {
        vm.prank(controller);
        vm.expectRevert(Vault.Vault__CannotLowerBacking.selector);
        vault.credit(address(asset), 1, IVault.Bucket.Redeem, IVault.Bucket.Team);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.credit(address(asset), 1, IVault.Bucket.Borrow, IVault.Bucket.Team);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.credit(address(asset), 1, IVault.Bucket.Collateral, IVault.Bucket.Team);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.credit(address(asset), 1, IVault.Bucket.None, IVault.Bucket.Team);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.credit(address(asset), 1, IVault.Bucket.Team, IVault.Bucket.Borrow);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.credit(address(asset), 1, IVault.Bucket.Team, IVault.Bucket.Collateral);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.credit(address(asset), 1, IVault.Bucket.Team, IVault.Bucket.None);
    }

    function testCreditRevertsAtomicallyWhenSourceUnderflows() public {
        _setBucket(IVault.Bucket.Treasury, address(asset), 10);

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        vault.credit(address(asset), 11, IVault.Bucket.Treasury, IVault.Bucket.Team);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 10);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 0);

        _setBucket(IVault.Bucket.Team, address(asset), 7);

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        vault.credit(address(asset), 8, IVault.Bucket.Team, IVault.Bucket.Treasury);

        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 7);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 10);
    }

    function testCreditsMovesCoreBucketsAsBatch() public {
        _setBucket(IVault.Bucket.Treasury, address(asset), 100);
        _setBucket(IVault.Bucket.Team, address(asset), 50);

        IVault.CreditCall[] memory calls = new IVault.CreditCall[](2);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Redeem, asset: address(asset), amount: 30
        });
        calls[1] = IVault.CreditCall({
            from: IVault.Bucket.Team, to: IVault.Bucket.Treasury, asset: address(asset), amount: 20
        });

        vm.prank(controller);
        vault.credits(calls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 90);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 30);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 30);
    }

    function testCreditsDuplicateSourceEntriesApplySequentiallyWhenValid() public {
        _setBucket(IVault.Bucket.Treasury, address(asset), 100);

        IVault.CreditCall[] memory calls = new IVault.CreditCall[](2);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Team, asset: address(asset), amount: 30
        });
        calls[1] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Redeem, asset: address(asset), amount: 20
        });

        vm.prank(controller);
        vault.credits(calls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 50);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 30);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 20);
    }

    function testCreditsBatchRevertsAtomicallyWhenLaterCreditUnderflows() public {
        _setBucket(IVault.Bucket.Treasury, address(asset), 100);
        _setBucket(IVault.Bucket.Team, address(asset), 10);

        IVault.CreditCall[] memory calls = new IVault.CreditCall[](2);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Redeem, asset: address(asset), amount: 25
        });
        calls[1] = IVault.CreditCall({
            from: IVault.Bucket.Team, to: IVault.Bucket.Treasury, asset: address(asset), amount: 11
        });

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        vault.credits(calls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 100);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 10);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 0);
    }

    function testCreditsDuplicateSourceEntriesRevertAtomicallyWhenLaterEntryUnderflows() public {
        _setBucket(IVault.Bucket.Treasury, address(asset), 40);

        IVault.CreditCall[] memory calls = new IVault.CreditCall[](2);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Team, asset: address(asset), amount: 30
        });
        calls[1] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Redeem, asset: address(asset), amount: 11
        });

        vm.prank(controller);
        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        vault.credits(calls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 40);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 0);
    }

    function testCreditsRejectsInvalidBucketsBeforeWriting() public {
        _setBucket(IVault.Bucket.Treasury, address(asset), 100);

        IVault.CreditCall[] memory calls = new IVault.CreditCall[](2);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Team, asset: address(asset), amount: 25
        });
        calls[1] =
            IVault.CreditCall({from: IVault.Bucket.Borrow, to: IVault.Bucket.Team, asset: address(asset), amount: 1});

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.credits(calls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 100);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 0);

        calls[1] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Borrow, asset: address(asset), amount: 1
        });

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.credits(calls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 100);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 0);

        calls[1] =
            IVault.CreditCall({from: IVault.Bucket.Redeem, to: IVault.Bucket.Team, asset: address(asset), amount: 1});

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__CannotLowerBacking.selector);
        vault.credits(calls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 100);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 0);
    }

    function testCreditsRejectsCollateralAndNoneBeforeWriting() public {
        _setBucket(IVault.Bucket.Treasury, address(asset), 100);

        IVault.CreditCall[] memory calls = new IVault.CreditCall[](2);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Team, asset: address(asset), amount: 25
        });

        calls[1] = IVault.CreditCall({
            from: IVault.Bucket.Collateral, to: IVault.Bucket.Team, asset: address(asset), amount: 1
        });
        _expectCreditsInvalidBucketWithoutWriting(calls);

        calls[1] =
            IVault.CreditCall({from: IVault.Bucket.None, to: IVault.Bucket.Team, asset: address(asset), amount: 1});
        _expectCreditsInvalidBucketWithoutWriting(calls);

        calls[1] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Collateral, asset: address(asset), amount: 1
        });
        _expectCreditsInvalidBucketWithoutWriting(calls);

        calls[1] =
            IVault.CreditCall({from: IVault.Bucket.Treasury, to: IVault.Bucket.None, asset: address(asset), amount: 1});
        _expectCreditsInvalidBucketWithoutWriting(calls);
    }

    function testSyncSurplusAccountsOnlyNewSurplusIntoCoreBuckets() public {
        asset.mint(address(vault), 100);

        vm.prank(controller);
        vault.syncSurplus(address(asset), IVault.Bucket.Redeem);

        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 100);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__NoSurplus.selector);
        vault.syncSurplus(address(asset), IVault.Bucket.Redeem);

        asset.mint(address(vault), 30);

        vm.prank(controller);
        vault.syncSurplus(address(asset), IVault.Bucket.Team);

        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 100);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 30);

        asset.mint(address(vault), 20);

        vm.prank(controller);
        vault.syncSurplus(address(asset), IVault.Bucket.Treasury);

        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 100);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 30);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 20);
    }

    function testSyncSurplusDoesNotDoubleCountExistingCoreAccounting() public {
        asset.mint(address(vault), 100);
        _setBucket(IVault.Bucket.Redeem, address(asset), 50);
        _setBucket(IVault.Bucket.Treasury, address(asset), 30);
        _setBucket(IVault.Bucket.Team, address(asset), 20);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__NoSurplus.selector);
        vault.syncSurplus(address(asset), IVault.Bucket.Redeem);

        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 50);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 30);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 20);

        asset.mint(address(vault), 1);

        vm.prank(controller);
        vault.syncSurplus(address(asset), IVault.Bucket.Redeem);

        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 51);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 30);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 20);
    }

    function testSyncSurplusRejectsNonCoreBuckets() public {
        asset.mint(address(vault), 100);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.syncSurplus(address(asset), IVault.Bucket.Borrow);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.syncSurplus(address(asset), IVault.Bucket.Collateral);

        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.syncSurplus(address(asset), IVault.Bucket.None);

        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 0);
    }

    function testBalanceViewsReadAssetsInKernelOrder() public {
        _setAssets(address(asset), address(secondAsset));
        _setBucket(IVault.Bucket.Redeem, address(asset), 11);
        _setBucket(IVault.Bucket.Redeem, address(secondAsset), 22);
        _setBucket(IVault.Bucket.Treasury, address(asset), 33);
        _setBucket(IVault.Bucket.Team, address(secondAsset), 44);

        IVault.AssetBalance[] memory backing = vault.backingBalances();
        IVault.AssetBalance[] memory treasury = vault.treasuryBalances();
        IVault.AssetBalance[] memory team = vault.teamBalances();

        assertEq(backing.length, 2);
        assertEq(backing[0].asset, address(asset));
        assertEq(backing[0].amount, 11);
        assertEq(backing[1].asset, address(secondAsset));
        assertEq(backing[1].amount, 22);

        assertEq(treasury.length, 2);
        assertEq(treasury[0].asset, address(asset));
        assertEq(treasury[0].amount, 33);
        assertEq(treasury[1].asset, address(secondAsset));
        assertEq(treasury[1].amount, 0);

        assertEq(team.length, 2);
        assertEq(team[0].asset, address(asset));
        assertEq(team[0].amount, 0);
        assertEq(team[1].asset, address(secondAsset));
        assertEq(team[1].amount, 44);
    }

    function testBalanceViewsReturnSingleAssetWithZeroBalances() public {
        address[] memory configuredAssets = new address[](1);
        configuredAssets[0] = address(asset);
        _setAssets(configuredAssets);

        IVault.AssetBalance[] memory backing = vault.backingBalances();
        IVault.AssetBalance[] memory treasury = vault.treasuryBalances();
        IVault.AssetBalance[] memory team = vault.teamBalances();

        assertEq(backing.length, 1);
        assertEq(backing[0].asset, address(asset));
        assertEq(backing[0].amount, 0);

        assertEq(treasury.length, 1);
        assertEq(treasury[0].asset, address(asset));
        assertEq(treasury[0].amount, 0);

        assertEq(team.length, 1);
        assertEq(team[0].asset, address(asset));
        assertEq(team[0].amount, 0);
    }

    function testBalanceViewsPreserveDuplicateAssetsAndZeroBalances() public {
        address[] memory configuredAssets = new address[](3);
        configuredAssets[0] = address(asset);
        configuredAssets[1] = address(secondAsset);
        configuredAssets[2] = address(asset);
        _setAssets(configuredAssets);
        _setBucket(IVault.Bucket.Redeem, address(asset), 12);
        _setBucket(IVault.Bucket.Treasury, address(asset), 34);
        _setBucket(IVault.Bucket.Team, address(secondAsset), 56);

        IVault.AssetBalance[] memory backing = vault.backingBalances();
        IVault.AssetBalance[] memory treasury = vault.treasuryBalances();
        IVault.AssetBalance[] memory team = vault.teamBalances();

        assertEq(backing.length, 3);
        assertEq(backing[0].asset, address(asset));
        assertEq(backing[0].amount, 12);
        assertEq(backing[1].asset, address(secondAsset));
        assertEq(backing[1].amount, 0);
        assertEq(backing[2].asset, address(asset));
        assertEq(backing[2].amount, 12);

        assertEq(treasury.length, 3);
        assertEq(treasury[0].asset, address(asset));
        assertEq(treasury[0].amount, 34);
        assertEq(treasury[1].asset, address(secondAsset));
        assertEq(treasury[1].amount, 0);
        assertEq(treasury[2].asset, address(asset));
        assertEq(treasury[2].amount, 34);

        assertEq(team.length, 3);
        assertEq(team[0].asset, address(asset));
        assertEq(team[0].amount, 0);
        assertEq(team[1].asset, address(secondAsset));
        assertEq(team[1].amount, 56);
        assertEq(team[2].asset, address(asset));
        assertEq(team[2].amount, 0);
    }

    function testBalanceViewsReturnEmptyArraysWhenNoAssetsAreConfigured() public view {
        assertEq(vault.backingBalances().length, 0);
        assertEq(vault.treasuryBalances().length, 0);
        assertEq(vault.teamBalances().length, 0);
    }

    function _setAssets(address first, address second) internal {
        address[] memory assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
        _setAssets(assets);
    }

    function _setAssets(address[] memory assets) internal {
        bytes memory data = new bytes(assets.length * 32);
        for (uint256 i; i < assets.length;) {
            bytes32 assetWord = bytes32(uint256(uint160(assets[i])));
            assembly ("memory-safe") {
                mstore(add(add(data, 0x20), shl(5, i)), assetWord)
            }
            unchecked {
                ++i;
            }
        }

        vm.startPrank(controller);
        kernel.updateState(Slots.ASSETS_LENGTH_SLOT, bytes32(assets.length));
        kernel.updateState(Slots.ASSETS_BASE_SLOT, data);
        vm.stopPrank();
    }

    function _setBucket(IVault.Bucket bucket, address token, uint256 amount) internal {
        vm.prank(controller);
        kernel.updateState(_bucketSlot(bucket, token), bytes32(amount));
    }

    function _bucketValue(IVault.Bucket bucket, address token) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, token)));
    }

    function _expectCreditsInvalidBucketWithoutWriting(IVault.CreditCall[] memory calls) internal {
        vm.prank(controller);
        vm.expectRevert(Vault.Vault__InvalidBucket.selector);
        vault.credits(calls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 100);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(asset)), 0);
    }

    function _fuzzTransferShape(uint8 rawKind)
        internal
        pure
        returns (IVault.TransferType callType, IVault.Bucket toBucket, IVault.Bucket fromBucket)
    {
        uint8 kind = rawKind % 8;

        if (kind == 0) return (IVault.TransferType.Send, IVault.Bucket.Borrow, IVault.Bucket.Redeem);
        if (kind == 1) return (IVault.TransferType.Receive, IVault.Bucket.Redeem, IVault.Bucket.Borrow);
        if (kind == 2) return (IVault.TransferType.Send, IVault.Bucket.None, IVault.Bucket.Redeem);
        if (kind == 3) return (IVault.TransferType.Receive, IVault.Bucket.Treasury, IVault.Bucket.None);
        if (kind == 4) return (IVault.TransferType.Send, IVault.Bucket.None, IVault.Bucket.Treasury);
        if (kind == 5) return (IVault.TransferType.Send, IVault.Bucket.None, IVault.Bucket.Team);
        if (kind == 6) return (IVault.TransferType.Receive, IVault.Bucket.Collateral, IVault.Bucket.None);
        return (IVault.TransferType.Send, IVault.Bucket.None, IVault.Bucket.Collateral);
    }

    function _bucketIndex(IVault.Bucket bucket) internal pure returns (uint256) {
        if (bucket == IVault.Bucket.Borrow) return 0;
        if (bucket == IVault.Bucket.Redeem) return 1;
        if (bucket == IVault.Bucket.Treasury) return 2;
        if (bucket == IVault.Bucket.Team) return 3;
        if (bucket == IVault.Bucket.Collateral) return 4;
        revert("invalid bucket index");
    }

    function _bucketSlot(IVault.Bucket bucket, address token) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, token);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERL_SLOT, token);
        revert("invalid bucket");
    }

    function _slot(bytes32 namespace, address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, token));
    }
}
