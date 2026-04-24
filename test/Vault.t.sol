///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, stdError} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IController} from "../src/interfaces/IController.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {Kernel} from "../src/Kernel.sol";
import {Vault} from "../src/Vault.sol";

contract VaultControllerMock is IController {
    mapping(address => bool) internal permissioned;
    mapping(address => bool) internal access;

    function setPermissioned(address caller, bool isAllowed) external {
        permissioned[caller] = isAllowed;
    }

    function isPermissioned(address caller) external view returns (bool) {
        return permissioned[caller];
    }

    function setAccess(address caller, bool isAllowed) external {
        access[caller] = isAllowed;
    }

    function vaultAccess(address caller) external view returns (bool) {
        return access[caller];
    }
}

contract ERC20Mock is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VaultHarness is Vault {
    constructor(address controller, address kernel) Vault(controller, kernel) {}

    function exposedAccountedBalance(address asset) external view returns (uint256) {
        return _accountedBalance(asset);
    }

    function exposedNamespaceUnchecked(uint256 raw) external pure returns (bytes32) {
        IVault.Bucket bucket;
        assembly ("memory-safe") {
            bucket := raw
        }
        return _namespace(bucket);
    }

    function exposedReadAssets() external view returns (address[] memory) {
        return _readAssets();
    }
}

contract VaultTest is Test {
    bytes32 internal constant TREASURY_AMOUNT_SLOT = 0x60b5ab302bbeea0c83917cc1819e272c0b2ec70ceb2f138a32d5caae015750f3;
    bytes32 internal constant BACKING_AMOUNT_SLOT = 0x0024fb7f9ccb99221958049f86297fab788b0f0b640b3f50254c9bd56ccf0930;
    bytes32 internal constant TEAM_AMOUNT_SLOT = 0x1da01d8de7381a167e82accc7aa1ccc9122c1143bd9e81a0e9456adadd05678a;
    bytes32 internal constant ASSET_COUNT_SLOT = 0xd635f114cc21f2834e679c2555d4ff475d8d6f01003ca6da1dfee13ecdf62738;
    bytes32 internal constant ASSET_BASE_SLOT = 0x1a27d05721698994f0e5408d30550ae696157097140b4a919a081b62c08e625f;

    event SurplusSynced(address indexed asset, IVault.Bucket indexed bucket, uint256 amount);

    VaultControllerMock internal controller;
    Kernel internal kernel;
    VaultHarness internal vault;
    ERC20Mock internal asset;
    ERC20Mock internal assetTwo;

    address internal constant STRANGER = address(0xCAFE);
    address internal constant RECIPIENT = address(0xBEEF);
    address internal constant RECIPIENT_TWO = address(0xF00D);

    function setUp() public {
        controller = new VaultControllerMock();
        kernel = new Kernel(address(controller));
        vault = new VaultHarness(address(controller), address(kernel));
        asset = new ERC20Mock("Mock Asset", "MOCK");
        assetTwo = new ERC20Mock("Second Asset", "MOCK2");

        controller.setPermissioned(address(vault), true);
        controller.setPermissioned(address(this), true);
        controller.setAccess(address(this), true);

        asset.mint(address(this), 1_000e18);
        assetTwo.mint(address(this), 1_000e18);
        asset.approve(address(vault), type(uint256).max);
        assetTwo.approve(address(vault), type(uint256).max);
    }

    function testConstructorRevertsForZeroController() public {
        vm.expectRevert(Vault.Vault__MisconfiguredSetup.selector);
        new VaultHarness(address(0), address(kernel));
    }

    function testConstructorRevertsForZeroKernel() public {
        vm.expectRevert(Vault.Vault__MisconfiguredSetup.selector);
        new VaultHarness(address(controller), address(0));
    }

    function testTransferTreasuryAssetTransfersTokensAndUpdatesAccounting() public {
        asset.mint(address(vault), 100e18);
        _seedBucket(TREASURY_AMOUNT_SLOT, address(asset), 100e18);

        vault.transferTreasuryAsset(IVault.TreasuryCall({asset: address(asset), to: RECIPIENT, amount: 40e18}));

        assertEq(asset.balanceOf(RECIPIENT), 40e18);
        assertEq(asset.balanceOf(address(vault)), 60e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(asset)))), 60e18);
    }

    function testTransferTreasuryAssetRevertsForUnauthorizedCaller() public {
        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.transferTreasuryAsset(IVault.TreasuryCall({asset: address(asset), to: RECIPIENT, amount: 1e18}));
    }

    function testTransferTreasuryAssetsTransfersTokensAndUpdatesAccounting() public {
        asset.mint(address(vault), 90e18);
        assetTwo.mint(address(vault), 80e18);
        _seedBucket(TREASURY_AMOUNT_SLOT, address(asset), 90e18);
        _seedBucket(TREASURY_AMOUNT_SLOT, address(assetTwo), 80e18);

        IVault.TreasuryCall[] memory calls = new IVault.TreasuryCall[](2);
        calls[0] = IVault.TreasuryCall({asset: address(asset), to: RECIPIENT, amount: 30e18});
        calls[1] = IVault.TreasuryCall({asset: address(assetTwo), to: RECIPIENT_TWO, amount: 20e18});

        vault.transferTreasuryAssets(calls);

        assertEq(asset.balanceOf(RECIPIENT), 30e18);
        assertEq(assetTwo.balanceOf(RECIPIENT_TWO), 20e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(asset)))), 60e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(assetTwo)))), 60e18);
    }

    function testTransferTreasuryAssetsRevertsForUnauthorizedCaller() public {
        IVault.TreasuryCall[] memory calls = new IVault.TreasuryCall[](1);
        calls[0] = IVault.TreasuryCall({asset: address(asset), to: RECIPIENT, amount: 1e18});

        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.transferTreasuryAssets(calls);
    }

    function testTransferRedeemTransfersTokensAndUpdatesAccounting() public {
        asset.mint(address(vault), 100e18);
        assetTwo.mint(address(vault), 60e18);
        _seedBucket(BACKING_AMOUNT_SLOT, address(asset), 100e18);
        _seedBucket(BACKING_AMOUNT_SLOT, address(assetTwo), 60e18);

        IVault.RedeemCall[] memory calls = new IVault.RedeemCall[](2);
        calls[0] = IVault.RedeemCall({asset: address(asset), amount: 25e18});
        calls[1] = IVault.RedeemCall({asset: address(assetTwo), amount: 15e18});

        vault.transferRedeem(RECIPIENT, calls);

        assertEq(asset.balanceOf(RECIPIENT), 25e18);
        assertEq(assetTwo.balanceOf(RECIPIENT), 15e18);
        assertEq(uint256(kernel.viewData(_amountSlot(BACKING_AMOUNT_SLOT, address(asset)))), 75e18);
        assertEq(uint256(kernel.viewData(_amountSlot(BACKING_AMOUNT_SLOT, address(assetTwo)))), 45e18);
    }

    function testTransferRedeemRevertsForUnauthorizedCaller() public {
        IVault.RedeemCall[] memory calls = new IVault.RedeemCall[](1);
        calls[0] = IVault.RedeemCall({asset: address(asset), amount: 1e18});

        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.transferRedeem(RECIPIENT, calls);
    }

    function testTransferTeamAssetTransfersTokensAndUpdatesAccounting() public {
        asset.mint(address(vault), 30e18);
        _seedBucket(TEAM_AMOUNT_SLOT, address(asset), 30e18);

        vault.transferTeamAsset(IVault.TeamCall({to: RECIPIENT, asset: address(asset), amount: 10e18}));

        assertEq(asset.balanceOf(RECIPIENT), 10e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(asset)))), 20e18);
    }

    function testTransferTeamAssetRevertsForUnauthorizedCaller() public {
        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.transferTeamAsset(IVault.TeamCall({to: RECIPIENT, asset: address(asset), amount: 1e18}));
    }

    function testTransferTeamAssetsTransfersTokensAndUpdatesAccounting() public {
        asset.mint(address(vault), 25e18);
        assetTwo.mint(address(vault), 45e18);
        _seedBucket(TEAM_AMOUNT_SLOT, address(asset), 25e18);
        _seedBucket(TEAM_AMOUNT_SLOT, address(assetTwo), 45e18);

        IVault.TeamCall[] memory calls = new IVault.TeamCall[](2);
        calls[0] = IVault.TeamCall({to: RECIPIENT, asset: address(asset), amount: 5e18});
        calls[1] = IVault.TeamCall({to: RECIPIENT_TWO, asset: address(assetTwo), amount: 15e18});

        vault.transferTeamAssets(calls);

        assertEq(asset.balanceOf(RECIPIENT), 5e18);
        assertEq(assetTwo.balanceOf(RECIPIENT_TWO), 15e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(asset)))), 20e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(assetTwo)))), 30e18);
    }

    function testTransferTeamAssetsRevertsForUnauthorizedCaller() public {
        IVault.TeamCall[] memory calls = new IVault.TeamCall[](1);
        calls[0] = IVault.TeamCall({to: RECIPIENT, asset: address(asset), amount: 1e18});

        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.transferTeamAssets(calls);
    }

    function testReceiveAssetCreditsTreasuryBucket() public {
        vault.receiveAsset(
            IVault.ReceiveCall({
                from: address(this), asset: address(asset), amount: 50e18, bucket: IVault.Bucket.Treasury
            })
        );

        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(asset)))), 50e18);
        assertEq(uint256(kernel.viewData(_amountSlot(BACKING_AMOUNT_SLOT, address(asset)))), 0);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(asset)))), 0);
        assertEq(asset.balanceOf(address(vault)), 50e18);
    }

    function testReceiveAssetRevertsForUnauthorizedCaller() public {
        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.receiveAsset(
            IVault.ReceiveCall({
                from: address(this), asset: address(asset), amount: 1e18, bucket: IVault.Bucket.Backing
            })
        );
    }

    function testReceiveAssetsCreditsConfiguredBuckets() public {
        IVault.ReceiveCall[] memory calls = new IVault.ReceiveCall[](3);
        calls[0] = IVault.ReceiveCall({
            from: address(this), asset: address(asset), amount: 40e18, bucket: IVault.Bucket.Backing
        });
        calls[1] = IVault.ReceiveCall({
            from: address(this), asset: address(assetTwo), amount: 30e18, bucket: IVault.Bucket.Treasury
        });
        calls[2] =
            IVault.ReceiveCall({from: address(this), asset: address(asset), amount: 20e18, bucket: IVault.Bucket.Team});

        vault.receiveAssets(calls);

        assertEq(uint256(kernel.viewData(_amountSlot(BACKING_AMOUNT_SLOT, address(asset)))), 40e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(assetTwo)))), 30e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(asset)))), 20e18);
        assertEq(asset.balanceOf(address(vault)), 60e18);
        assertEq(assetTwo.balanceOf(address(vault)), 30e18);
    }

    function testReceiveAssetsRevertsForUnauthorizedCaller() public {
        IVault.ReceiveCall[] memory calls = new IVault.ReceiveCall[](1);
        calls[0] = IVault.ReceiveCall({
            from: address(this), asset: address(asset), amount: 1e18, bucket: IVault.Bucket.Backing
        });

        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.receiveAssets(calls);
    }

    function testCreditRebucketsAccounting() public {
        _seedBucket(TREASURY_AMOUNT_SLOT, address(asset), 25e18);

        vault.credit(address(asset), 10e18, IVault.Bucket.Treasury, IVault.Bucket.Team);

        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(asset)))), 15e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(asset)))), 10e18);
    }

    function testCreditRevertsForUnauthorizedCaller() public {
        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.credit(address(asset), 1e18, IVault.Bucket.Treasury, IVault.Bucket.Team);
    }

    function testCreditRevertsWhenLoweringBacking() public {
        vm.expectRevert(Vault.Vault__CannotLowerBacking.selector);
        vault.credit(address(asset), 1e18, IVault.Bucket.Backing, IVault.Bucket.Team);
    }

    function testCreditsRebucketAccounting() public {
        _seedBucket(TREASURY_AMOUNT_SLOT, address(asset), 20e18);
        _seedBucket(TEAM_AMOUNT_SLOT, address(asset), 15e18);
        _seedBucket(TEAM_AMOUNT_SLOT, address(assetTwo), 25e18);

        IVault.CreditCall[] memory calls = new IVault.CreditCall[](2);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Backing, asset: address(asset), amount: 8e18
        });
        calls[1] = IVault.CreditCall({
            from: IVault.Bucket.Team, to: IVault.Bucket.Treasury, asset: address(assetTwo), amount: 10e18
        });

        vault.credits(calls);

        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(asset)))), 12e18);
        assertEq(uint256(kernel.viewData(_amountSlot(BACKING_AMOUNT_SLOT, address(asset)))), 8e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(assetTwo)))), 15e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(assetTwo)))), 10e18);
    }

    function testCreditsRevertsForUnauthorizedCaller() public {
        IVault.CreditCall[] memory calls = new IVault.CreditCall[](1);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Treasury, to: IVault.Bucket.Team, asset: address(asset), amount: 1e18
        });

        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.credits(calls);
    }

    function testCreditsRevertsWhenLoweringBacking() public {
        IVault.CreditCall[] memory calls = new IVault.CreditCall[](1);
        calls[0] = IVault.CreditCall({
            from: IVault.Bucket.Backing, to: IVault.Bucket.Team, asset: address(asset), amount: 1e18
        });

        vm.expectRevert(Vault.Vault__CannotLowerBacking.selector);
        vault.credits(calls);
    }

    function testSyncSurplusCreditsUnaccountedTokens() public {
        asset.mint(address(vault), 15e18);
        _seedBucket(BACKING_AMOUNT_SLOT, address(asset), 4e18);
        _seedBucket(TREASURY_AMOUNT_SLOT, address(asset), 3e18);
        _seedBucket(TEAM_AMOUNT_SLOT, address(asset), 2e18);

        vm.expectEmit(true, true, false, true, address(vault));
        emit SurplusSynced(address(asset), IVault.Bucket.Team, 6e18);

        vault.syncSurplus(address(asset), IVault.Bucket.Team);

        assertEq(vault.exposedAccountedBalance(address(asset)), 15e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(asset)))), 8e18);
    }

    function testSyncSurplusRevertsForUnauthorizedCaller() public {
        vm.expectRevert(Vault.Vault__RestrictedAccess.selector);
        vm.prank(STRANGER);
        vault.syncSurplus(address(asset), IVault.Bucket.Backing);
    }

    function testSyncSurplusRevertsWhenNoSurplusExists() public {
        asset.mint(address(vault), 5e18);
        _seedBucket(BACKING_AMOUNT_SLOT, address(asset), 2e18);
        _seedBucket(TREASURY_AMOUNT_SLOT, address(asset), 2e18);
        _seedBucket(TEAM_AMOUNT_SLOT, address(asset), 1e18);

        vm.expectRevert(Vault.Vault__NoSurplus.selector);
        vault.syncSurplus(address(asset), IVault.Bucket.Backing);
    }

    function testBackingBalancesReturnsEmptyWhenNoAssetsAreSeeded() public view {
        IVault.AssetBalance[] memory balances = vault.backingBalances();
        assertEq(balances.length, 0);
    }

    function testTreasuryBalancesReturnsEmptyWhenNoAssetsAreSeeded() public view {
        IVault.AssetBalance[] memory balances = vault.treasuryBalances();
        assertEq(balances.length, 0);
    }

    function testExposedReadAssetsReturnsEmptyWhenNoAssetsAreSeeded() public view {
        address[] memory assetsRead = vault.exposedReadAssets();
        assertEq(assetsRead.length, 0);
    }

    function testBalanceViewsReturnSeededValues() public {
        address[] memory assets_ = new address[](2);
        assets_[0] = address(asset);
        assets_[1] = address(assetTwo);
        _seedAssets(assets_);
        _seedBucket(BACKING_AMOUNT_SLOT, address(asset), 11e18);
        _seedBucket(BACKING_AMOUNT_SLOT, address(assetTwo), 22e18);
        _seedBucket(TREASURY_AMOUNT_SLOT, address(asset), 33e18);
        _seedBucket(TREASURY_AMOUNT_SLOT, address(assetTwo), 44e18);

        IVault.AssetBalance[] memory backing = vault.backingBalances();
        IVault.AssetBalance[] memory treasury = vault.treasuryBalances();
        address[] memory assetsRead = vault.exposedReadAssets();

        assertEq(assetsRead.length, 2);
        assertEq(assetsRead[0], address(asset));
        assertEq(assetsRead[1], address(assetTwo));

        assertEq(backing.length, 2);
        assertEq(backing[0].asset, address(asset));
        assertEq(backing[0].amount, 11e18);
        assertEq(backing[1].asset, address(assetTwo));
        assertEq(backing[1].amount, 22e18);

        assertEq(treasury.length, 2);
        assertEq(treasury[0].asset, address(asset));
        assertEq(treasury[0].amount, 33e18);
        assertEq(treasury[1].asset, address(assetTwo));
        assertEq(treasury[1].amount, 44e18);
    }

    function testExposedNamespaceUncheckedPanicsForInvalidBucket() public {
        vm.expectRevert(stdError.enumConversionError);
        vault.exposedNamespaceUnchecked(3);
    }

    function _seedAssets(address[] memory assets_) internal {
        kernel.updateState(ASSET_COUNT_SLOT, bytes32(assets_.length));
        for (uint256 i = 0; i < assets_.length;) {
            kernel.updateState(_slotOffset(ASSET_BASE_SLOT, i), bytes32(uint256(uint160(assets_[i]))));
            unchecked {
                ++i;
            }
        }
    }

    function _seedBucket(bytes32 namespace, address token, uint256 amount) internal {
        kernel.updateState(_amountSlot(namespace, token), bytes32(amount));
    }

    function _amountSlot(bytes32 namespace, address token) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(token, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }

    function _slotOffset(bytes32 slot, uint256 offset) internal pure returns (bytes32) {
        return bytes32(uint256(slot) + offset);
    }
}
