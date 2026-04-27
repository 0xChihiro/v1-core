///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, stdError} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Controller} from "../src/Controller.sol";
import {IController, IModule, IPolicy, Keycode, Permission} from "../src/interfaces/IController.sol";
import {IVault as IVaultCore} from "../src/interfaces/IVault.sol";
import {Kernel} from "../src/Kernel.sol";
import {Slots} from "../src/libraries/Slots.sol";
import {Vault} from "../src/Vault.sol";

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
        IVaultCore.Bucket bucket;
        assembly ("memory-safe") {
            bucket := raw
        }
        return _namespace(bucket);
    }

    function exposedReadAssets() external view returns (address[] memory) {
        return _readAssets();
    }
}

contract PriceModule is IModule {
    Keycode internal constant PRICE = Keycode.wrap(0x5052494345);

    bool public initialized;

    function keycode() external pure returns (Keycode) {
        return PRICE;
    }

    function version() external pure returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    function init() external {
        initialized = true;
    }

    function price() external pure returns (uint256) {
        return 1;
    }
}

contract BadKeycodeModule is IModule {
    function keycode() external pure returns (Keycode) {
        return Keycode.wrap(0x7072696365);
    }

    function version() external pure returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    function init() external {}
}

contract AuctionModule is IModule {
    Keycode internal constant AUCTION = Keycode.wrap(0x415543544E);

    bool public initialized;

    function keycode() external pure returns (Keycode) {
        return AUCTION;
    }

    function version() external pure returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    function init() external {
        initialized = true;
    }

    function settle(Controller controller, Controller.Settlement calldata settlement) external {
        controller.settle(settlement);
    }
}

contract AuctionPolicy is IPolicy {
    Keycode internal constant AUCTION = Keycode.wrap(0x415543544E);
    Keycode internal constant PRICE = Keycode.wrap(0x5052494345);

    bool public configured;

    function keycode() external pure returns (Keycode) {
        return AUCTION;
    }

    function configureDependencies() external returns (Keycode[] memory dependencies) {
        configured = true;
        dependencies = new Keycode[](1);
        dependencies[0] = PRICE;
    }

    function requestPermissions() external pure returns (Permission[] memory requests) {
        requests = new Permission[](1);
        requests[0] = Permission({keycode: PRICE, selector: PriceModule.price.selector});
    }
}

contract MissingDependencyPolicy is IPolicy {
    Keycode internal constant MISSING_POLICY = Keycode.wrap(0x4D4953534E);
    Keycode internal constant MISSING_MODULE = Keycode.wrap(0x4D49535347);

    function keycode() external pure returns (Keycode) {
        return MISSING_POLICY;
    }

    function configureDependencies() external pure returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](1);
        dependencies[0] = MISSING_MODULE;
    }

    function requestPermissions() external pure returns (Permission[] memory requests) {
        requests = new Permission[](0);
    }
}

contract VaultTest is Test {
    bytes32 internal constant TREASURY_AMOUNT_SLOT = Slots.TREASURY_AMOUNT_SLOT;
    bytes32 internal constant BACKING_AMOUNT_SLOT = Slots.BACKING_AMOUNT_SLOT;
    bytes32 internal constant TEAM_AMOUNT_SLOT = Slots.TEAM_AMOUNT_SLOT;
    bytes32 internal constant ASSET_COUNT_SLOT = Slots.ASSETS_LENGTH_SLOT;
    bytes32 internal constant ASSET_BASE_SLOT = Slots.ASSETS_BASE_SLOT;

    Controller internal controller;
    Kernel internal kernel;
    Vault internal vault;
    ERC20Mock internal asset;
    ERC20Mock internal assetTwo;

    address internal constant RECIPIENT = address(0xBEEF);
    address internal constant STRANGER = address(0xCAFE);
    address internal constant PROTOCOL_COLLECTOR = address(0xFEE);
    uint256 internal constant AUCTION_FEE_BPS = 250;
    Keycode internal constant EMPTY_KEYCODE = Keycode.wrap(0);
    Keycode internal constant PRICE_KEYCODE = Keycode.wrap(0x5052494345);
    Keycode internal constant AUCTION_KEYCODE = Keycode.wrap(0x415543544E);
    bytes32 internal constant BORROW_STATE_SLOT = keccak256("enten.test.borrow.state");
    uint256 internal constant BPS = 10_000;

    function setUp() public {
        controller = new Controller(address(this), PROTOCOL_COLLECTOR);
        kernel = controller.KERNEL();
        vault = controller.VAULT();

        asset = new ERC20Mock("Mock Asset", "MOCK");
        assetTwo = new ERC20Mock("Second Asset", "MOCK2");
        asset.mint(address(this), 1_000e18);
        assetTwo.mint(address(this), 1_000e18);
        asset.approve(address(vault), type(uint256).max);
        assetTwo.approve(address(vault), type(uint256).max);
    }

    function testControllerConstructorRevertsForZeroAdmin() public {
        vm.expectRevert(Controller.Controller__ZeroAddress.selector);
        new Controller(address(0), PROTOCOL_COLLECTOR);
    }

    function testControllerConstructorRevertsForZeroProtocolCollector() public {
        vm.expectRevert(Controller.Controller__ZeroAddress.selector);
        new Controller(address(this), address(0));
    }

    function testControllerGrantsAdminAndExecutorRoles() public view {
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(controller.hasRole(controller.EXECUTOR_ROLE(), address(this)));
    }

    function testControllerDeploysKernelAndVaultWithControllerOwnership() public view {
        assertEq(kernel.CONTROLLER(), address(controller));
        assertEq(kernel.accountingWriter(), address(vault));
        assertEq(vault.CONTROLLER(), address(controller));
        assertEq(address(vault.KERNEL()), address(kernel));
        assertEq(controller.TOKEN().CONTROLLER(), address(controller));
        assertEq(controller.PROTOCOL_COLLECTOR(), PROTOCOL_COLLECTOR);
    }

    function testExecuteRevertsForUnauthorizedCaller() public {
        PriceModule module = new PriceModule();
        bytes32 role = controller.EXECUTOR_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, role)
        );
        vm.prank(STRANGER);
        controller.execute(IController.Action.InstallModule, address(module));
    }

    function testInstallModuleRegistersKeycodeAndInitializesModule() public {
        PriceModule module = new PriceModule();
        Keycode price = PRICE_KEYCODE;

        vm.expectEmit(true, true, false, true, address(controller));
        emit Controller.ModuleInstalled(price, address(module));

        controller.execute(IController.Action.InstallModule, address(module));

        assertEq(controller.moduleForKeycode(price), address(module));
        assertEq(Keycode.unwrap(controller.keycodeForModule(address(module))), Keycode.unwrap(price));
        assertEq(Keycode.unwrap(controller.moduleKeycodeAt(0)), Keycode.unwrap(price));
        assertTrue(module.initialized());
    }

    function testActivateModuleRequiresInstalledModule() public {
        PriceModule module = new PriceModule();

        vm.expectRevert(abi.encodeWithSelector(Controller.Controller__ModuleNotInstalled.selector, EMPTY_KEYCODE));
        controller.execute(IController.Action.ActivateModule, address(module));
    }

    function testActivateModuleMarksInstalledModuleActive() public {
        PriceModule module = new PriceModule();
        Keycode price = PRICE_KEYCODE;

        controller.execute(IController.Action.InstallModule, address(module));
        controller.execute(IController.Action.ActivateModule, address(module));

        assertTrue(controller.activeModules(price));
    }

    function testInstallModuleRevertsForInvalidKeycode() public {
        BadKeycodeModule module = new BadKeycodeModule();

        vm.expectRevert();
        controller.execute(IController.Action.InstallModule, address(module));
    }

    function testInstallModuleRevertsForNonContractTarget() public {
        vm.expectRevert(abi.encodeWithSelector(Controller.Controller__TargetNotAContract.selector, STRANGER));
        controller.execute(IController.Action.InstallModule, STRANGER);
    }

    function testInstallModuleRevertsForDuplicateKeycode() public {
        PriceModule module = new PriceModule();
        PriceModule duplicate = new PriceModule();

        controller.execute(IController.Action.InstallModule, address(module));

        vm.expectRevert();
        controller.execute(IController.Action.InstallModule, address(duplicate));
    }

    function testUpgradeModuleReplacesModuleForKeycode() public {
        PriceModule oldModule = new PriceModule();
        PriceModule newModule = new PriceModule();
        Keycode price = PRICE_KEYCODE;

        controller.execute(IController.Action.InstallModule, address(oldModule));
        controller.execute(IController.Action.UpgradeModule, address(newModule));

        assertEq(controller.moduleForKeycode(price), address(newModule));
        assertEq(Keycode.unwrap(controller.keycodeForModule(address(oldModule))), Keycode.unwrap(EMPTY_KEYCODE));
        assertEq(Keycode.unwrap(controller.keycodeForModule(address(newModule))), Keycode.unwrap(price));
        assertTrue(newModule.initialized());
    }

    function testInstallPolicyRegistersKeycode() public {
        AuctionPolicy policy = new AuctionPolicy();
        Keycode auction = AUCTION_KEYCODE;

        vm.expectEmit(true, true, false, true, address(controller));
        emit Controller.PolicyInstalled(auction, address(policy));

        controller.execute(IController.Action.InstallPolicy, address(policy));

        assertEq(controller.policyForKeycode(auction), address(policy));
        assertEq(Keycode.unwrap(controller.keycodeForPolicy(address(policy))), Keycode.unwrap(auction));
        assertEq(Keycode.unwrap(controller.policyKeycodeAt(0)), Keycode.unwrap(auction));
    }

    function testActivatePolicyConfiguresDependenciesAndPermissions() public {
        PriceModule module = new PriceModule();
        AuctionPolicy policy = new AuctionPolicy();
        Keycode price = PRICE_KEYCODE;
        Keycode auction = AUCTION_KEYCODE;

        controller.execute(IController.Action.InstallModule, address(module));
        controller.execute(IController.Action.ActivateModule, address(module));
        controller.execute(IController.Action.InstallPolicy, address(policy));
        controller.execute(IController.Action.ActivatePolicy, address(policy));

        assertTrue(controller.activePolicies(auction));
        assertTrue(policy.configured());
        assertEq(Keycode.unwrap(controller.policyDependencyAt(auction, 0)), Keycode.unwrap(price));
        assertTrue(controller.policyPermissions(price, auction, PriceModule.price.selector));
    }

    function testActivatePolicyRevertsWhenDependencyMissing() public {
        MissingDependencyPolicy policy = new MissingDependencyPolicy();

        controller.execute(IController.Action.InstallPolicy, address(policy));

        vm.expectRevert();
        controller.execute(IController.Action.ActivatePolicy, address(policy));
    }

    function testUpgradePolicyReplacesPolicyAndPreservesActiveState() public {
        PriceModule module = new PriceModule();
        AuctionPolicy oldPolicy = new AuctionPolicy();
        AuctionPolicy newPolicy = new AuctionPolicy();
        Keycode auction = AUCTION_KEYCODE;
        Keycode price = PRICE_KEYCODE;

        controller.execute(IController.Action.InstallModule, address(module));
        controller.execute(IController.Action.ActivateModule, address(module));
        controller.execute(IController.Action.InstallPolicy, address(oldPolicy));
        controller.execute(IController.Action.ActivatePolicy, address(oldPolicy));

        controller.execute(IController.Action.UpgradePolicy, address(newPolicy));

        assertEq(controller.policyForKeycode(auction), address(newPolicy));
        assertEq(Keycode.unwrap(controller.keycodeForPolicy(address(oldPolicy))), Keycode.unwrap(EMPTY_KEYCODE));
        assertEq(Keycode.unwrap(controller.keycodeForPolicy(address(newPolicy))), Keycode.unwrap(auction));
        assertTrue(controller.activePolicies(auction));
        assertTrue(controller.policyPermissions(price, auction, PriceModule.price.selector));
    }

    function testSetMintPermissionUpdatesMintPermission() public {
        AuctionModule module = new AuctionModule();

        controller.execute(IController.Action.InstallModule, address(module));
        controller.execute(IController.Action.ActivateModule, address(module));

        vm.expectEmit(true, false, false, true, address(controller));
        emit Controller.MintPermissionUpdated(AUCTION_KEYCODE, true);

        controller.setMintPermission(AUCTION_KEYCODE, true);

        assertTrue(controller.mintPermissions(AUCTION_KEYCODE));
    }

    function testSetStatePermissionUpdatesNamespacePermission() public {
        _installActiveAuctionModule();

        vm.expectEmit(true, true, false, true, address(controller));
        emit Controller.StatePermissionUpdated(AUCTION_KEYCODE, BORROW_STATE_SLOT, true);

        controller.setStatePermission(AUCTION_KEYCODE, BORROW_STATE_SLOT, true);

        assertTrue(controller.statePermissions(AUCTION_KEYCODE, BORROW_STATE_SLOT));
    }

    function testSetMintPermissionRevertsForInactiveModule() public {
        AuctionModule module = new AuctionModule();

        controller.execute(IController.Action.InstallModule, address(module));

        vm.expectRevert(abi.encodeWithSelector(Controller.Controller__ModuleNotActive.selector, AUCTION_KEYCODE));
        controller.setMintPermission(AUCTION_KEYCODE, true);
    }

    function testSettleRevertsForMintWithoutPermission() public {
        AuctionModule module = _installActiveAuctionModule();
        _setMaxSupply(1_000_000e18);
        Controller.Settlement memory settlement = _auctionSettlement();

        vm.expectRevert(abi.encodeWithSelector(Controller.Controller__MintPermissionDenied.selector, AUCTION_KEYCODE));
        module.settle(controller, settlement);
    }

    function testSettleRevertsWhenMintExceedsMaxSupply() public {
        AuctionModule module = _installActiveAuctionModule();
        controller.setMintPermission(AUCTION_KEYCODE, true);
        _setMaxSupply(50e18);
        Controller.Settlement memory settlement = _auctionSettlement();

        vm.expectRevert(abi.encodeWithSelector(Controller.Controller__MintExceedsMaxSupply.selector, 100e18, 50e18));
        module.settle(controller, settlement);
    }

    function testSettleWithMintsSettlesMultipleAssetsAndCreditsBuckets() public {
        AuctionModule module = _installActiveAuctionModule();
        controller.setMintPermission(AUCTION_KEYCODE, true);
        _setMaxSupply(1_000_000e18);
        Controller.Settlement memory settlement = _auctionSettlement();

        module.settle(controller, settlement);

        uint256 firstProtocolCut = _protocolCut(1_000e18);
        uint256 secondProtocolCut = _protocolCut(500e18);

        assertEq(asset.balanceOf(address(vault)), 1_000e18 - firstProtocolCut);
        assertEq(assetTwo.balanceOf(address(vault)), 500e18 - secondProtocolCut);
        assertEq(asset.balanceOf(controller.PROTOCOL_COLLECTOR()), firstProtocolCut);
        assertEq(assetTwo.balanceOf(controller.PROTOCOL_COLLECTOR()), secondProtocolCut);

        assertEq(uint256(kernel.viewData(_amountSlot(BACKING_AMOUNT_SLOT, address(asset)))), 300e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(asset)))), 200e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(asset)))), 475e18);

        assertEq(uint256(kernel.viewData(_amountSlot(BACKING_AMOUNT_SLOT, address(assetTwo)))), 100e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(assetTwo)))), 50e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(assetTwo)))), 337.5e18);
        assertEq(controller.TOKEN().balanceOf(address(this)), 100e18);
    }

    function testSettleAppliesPermittedStateUpdates() public {
        AuctionModule module = _installActiveAuctionModule();
        controller.setStatePermission(AUCTION_KEYCODE, BORROW_STATE_SLOT, true);
        Controller.Settlement memory settlement =
            _stateUpdateSettlement(BORROW_STATE_SLOT, Controller.StateOp.Set, bytes32(uint256(123)));

        module.settle(controller, settlement);

        assertEq(kernel.viewData(BORROW_STATE_SLOT), bytes32(uint256(123)));
    }

    function testSettleRevertsForStateUpdateWithoutPermission() public {
        AuctionModule module = _installActiveAuctionModule();
        Controller.Settlement memory settlement =
            _stateUpdateSettlement(BORROW_STATE_SLOT, Controller.StateOp.Set, bytes32(uint256(123)));

        vm.expectRevert(
            abi.encodeWithSelector(Controller.Controller__StatePermissionDenied.selector, BORROW_STATE_SLOT)
        );
        module.settle(controller, settlement);
    }

    function testSettleRevertsWhenStateUpdateLowersRegisteredBacking() public {
        AuctionModule module = _installActiveAuctionModule();
        _seedControllerAssets();
        _storeControllerBucket(BACKING_AMOUNT_SLOT, address(asset), 10e18);
        bytes32 backingSlot = _amountSlot(BACKING_AMOUNT_SLOT, address(asset));
        controller.setStatePermission(AUCTION_KEYCODE, backingSlot, true);
        Controller.Settlement memory settlement =
            _stateUpdateSettlement(backingSlot, Controller.StateOp.Sub, bytes32(uint256(1e18)));

        vm.expectRevert(
            abi.encodeWithSelector(Controller.Controller__BackingInvariantBreach.selector, address(asset), 10e18, 9e18)
        );
        module.settle(controller, settlement);
    }

    function testSettleRevertsForOverAllocatedAsset() public {
        AuctionModule module = _installActiveAuctionModule();
        controller.setMintPermission(AUCTION_KEYCODE, true);
        _setMaxSupply(1_000_000e18);
        Controller.Settlement memory settlement = _auctionSettlement();
        settlement.credits[1].amount = 700e18;

        vm.expectRevert(abi.encodeWithSelector(Controller.Controller__SettlementOverAllocated.selector, address(asset)));
        module.settle(controller, settlement);
    }

    function testSettleRevertsForZeroPayer() public {
        AuctionModule module = _installActiveAuctionModule();
        controller.setMintPermission(AUCTION_KEYCODE, true);
        Controller.Settlement memory settlement = _auctionSettlement();
        settlement.payer = address(0);

        vm.expectRevert(Controller.Controller__ZeroAddress.selector);
        module.settle(controller, settlement);
    }

    function testSettleWithoutMintsDoesNotChargeProtocolFee() public {
        AuctionModule module = _installActiveAuctionModule();
        Controller.Settlement memory settlement = _liquiditySettlement();

        module.settle(controller, settlement);

        assertEq(asset.balanceOf(address(vault)), 100e18);
        assertEq(asset.balanceOf(controller.PROTOCOL_COLLECTOR()), 0);
        assertEq(uint256(kernel.viewData(_amountSlot(BACKING_AMOUNT_SLOT, address(asset)))), 70e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TEAM_AMOUNT_SLOT, address(asset)))), 5e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(asset)))), 25e18);
        assertEq(controller.TOKEN().totalSupply(), 0);
    }

    function testVaultConstructorRevertsForZeroController() public {
        vm.expectRevert(Vault.Vault__MisconfiguredSetup.selector);
        new Vault(address(0), address(kernel));
    }

    function testVaultConstructorRevertsForZeroKernel() public {
        vm.expectRevert(Vault.Vault__MisconfiguredSetup.selector);
        new Vault(address(controller), address(0));
    }

    function testVaultTransferRevertsWhenCallerIsNotController() public {
        vm.expectRevert(Vault.Vault__OnlyController.selector);
        vault.transferTreasuryAsset(IVaultCore.TreasuryCall({asset: address(asset), to: RECIPIENT, amount: 1e18}));
    }

    function testVaultTransferTreasuryAssetAllowsController() public {
        asset.mint(address(vault), 100e18);
        _storeBucket(kernel, TREASURY_AMOUNT_SLOT, address(asset), 100e18);

        vm.prank(address(controller));
        vault.transferTreasuryAsset(IVaultCore.TreasuryCall({asset: address(asset), to: RECIPIENT, amount: 40e18}));

        assertEq(asset.balanceOf(RECIPIENT), 40e18);
        assertEq(asset.balanceOf(address(vault)), 60e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(asset)))), 60e18);
    }

    function testVaultReceiveAssetAllowsController() public {
        vm.prank(address(controller));
        vault.receiveAsset(
            IVaultCore.ReceiveCall({
                from: address(this), asset: address(asset), amount: 50e18, bucket: IVaultCore.Bucket.Treasury
            })
        );

        assertEq(asset.balanceOf(address(vault)), 50e18);
        assertEq(uint256(kernel.viewData(_amountSlot(TREASURY_AMOUNT_SLOT, address(asset)))), 50e18);
    }

    function testBackingBalancesReturnsEmptyWhenNoAssetsAreSeeded() public {
        (Kernel readKernel, VaultHarness readVault) = _deployReadHarness();

        IVaultCore.AssetBalance[] memory balances = readVault.backingBalances();

        assertEq(address(readKernel), address(readVault.KERNEL()));
        assertEq(balances.length, 0);
    }

    function testTreasuryBalancesReturnsEmptyWhenNoAssetsAreSeeded() public {
        (, VaultHarness readVault) = _deployReadHarness();

        IVaultCore.AssetBalance[] memory balances = readVault.treasuryBalances();

        assertEq(balances.length, 0);
    }

    function testExposedReadAssetsReturnsEmptyWhenNoAssetsAreSeeded() public {
        (, VaultHarness readVault) = _deployReadHarness();

        address[] memory assetsRead = readVault.exposedReadAssets();

        assertEq(assetsRead.length, 0);
    }

    function testBalanceViewsReturnSeededValues() public {
        (Kernel readKernel, VaultHarness readVault) = _deployReadHarness();
        address[] memory assets_ = new address[](2);
        assets_[0] = address(asset);
        assets_[1] = address(assetTwo);
        _seedAssets(readKernel, assets_);
        _seedBucket(readKernel, BACKING_AMOUNT_SLOT, address(asset), 11e18);
        _seedBucket(readKernel, BACKING_AMOUNT_SLOT, address(assetTwo), 22e18);
        _seedBucket(readKernel, TREASURY_AMOUNT_SLOT, address(asset), 33e18);
        _seedBucket(readKernel, TREASURY_AMOUNT_SLOT, address(assetTwo), 44e18);

        IVaultCore.AssetBalance[] memory backing = readVault.backingBalances();
        IVaultCore.AssetBalance[] memory treasury = readVault.treasuryBalances();
        address[] memory assetsRead = readVault.exposedReadAssets();

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

    function testExposedAccountedBalanceReturnsSeededBucketSum() public {
        (Kernel readKernel, VaultHarness readVault) = _deployReadHarness();
        _seedBucket(readKernel, BACKING_AMOUNT_SLOT, address(asset), 4e18);
        _seedBucket(readKernel, TREASURY_AMOUNT_SLOT, address(asset), 3e18);
        _seedBucket(readKernel, TEAM_AMOUNT_SLOT, address(asset), 2e18);

        assertEq(readVault.exposedAccountedBalance(address(asset)), 9e18);
    }

    function testExposedNamespaceUncheckedPanicsForInvalidBucket() public {
        (, VaultHarness readVault) = _deployReadHarness();

        vm.expectRevert(stdError.enumConversionError);
        readVault.exposedNamespaceUnchecked(3);
    }

    function _deployReadHarness() internal returns (Kernel readKernel, VaultHarness readVault) {
        readKernel = new Kernel(address(this));
        readVault = new VaultHarness(address(this), address(readKernel));
    }

    function _installActiveAuctionModule() internal returns (AuctionModule module) {
        module = new AuctionModule();
        controller.execute(IController.Action.InstallModule, address(module));
        controller.execute(IController.Action.ActivateModule, address(module));
    }

    function _auctionSettlement() internal view returns (Controller.Settlement memory settlement) {
        settlement.payer = address(this);
        settlement.receipts = new Controller.Receipt[](2);
        settlement.receipts[0] = Controller.Receipt({asset: address(asset), amount: 1_000e18});
        settlement.receipts[1] = Controller.Receipt({asset: address(assetTwo), amount: 500e18});

        settlement.credits = new Controller.Credit[](4);
        settlement.credits[0] =
            Controller.Credit({asset: address(asset), to: IVaultCore.Bucket.Backing, amount: 300e18});
        settlement.credits[1] = Controller.Credit({asset: address(asset), to: IVaultCore.Bucket.Team, amount: 200e18});
        settlement.credits[2] =
            Controller.Credit({asset: address(assetTwo), to: IVaultCore.Bucket.Backing, amount: 100e18});
        settlement.credits[3] = Controller.Credit({asset: address(assetTwo), to: IVaultCore.Bucket.Team, amount: 50e18});

        settlement.mints = new Controller.Mint[](1);
        settlement.mints[0] = Controller.Mint({to: address(this), amount: 100e18});
        settlement.stateUpdates = new Controller.StateUpdate[](0);
    }

    function _liquiditySettlement() internal view returns (Controller.Settlement memory settlement) {
        settlement.payer = address(this);
        settlement.receipts = new Controller.Receipt[](1);
        settlement.receipts[0] = Controller.Receipt({asset: address(asset), amount: 100e18});

        settlement.credits = new Controller.Credit[](2);
        settlement.credits[0] = Controller.Credit({asset: address(asset), to: IVaultCore.Bucket.Backing, amount: 70e18});
        settlement.credits[1] = Controller.Credit({asset: address(asset), to: IVaultCore.Bucket.Team, amount: 5e18});

        settlement.mints = new Controller.Mint[](0);
        settlement.stateUpdates = new Controller.StateUpdate[](0);
    }

    function _stateUpdateSettlement(bytes32 namespace, Controller.StateOp op, bytes32 data)
        internal
        pure
        returns (Controller.Settlement memory settlement)
    {
        settlement.payer = address(0);
        settlement.receipts = new Controller.Receipt[](0);
        settlement.credits = new Controller.Credit[](0);
        settlement.mints = new Controller.Mint[](0);
        settlement.stateUpdates = new Controller.StateUpdate[](1);
        settlement.stateUpdates[0] = Controller.StateUpdate({
            namespace: namespace, derivation: Controller.SlotDerivation.Direct, key: bytes32(0), op: op, data: data
        });
    }

    function _setMaxSupply(uint256 maxSupply) internal {
        vm.prank(address(controller));
        kernel.updateState(Slots.MAX_SUPPLY_SLOT, bytes32(maxSupply));
    }

    function _seedControllerAssets() internal {
        address[] memory assets_ = new address[](1);
        assets_[0] = address(asset);

        vm.startPrank(address(controller));
        kernel.updateState(ASSET_COUNT_SLOT, bytes32(assets_.length));
        kernel.updateState(ASSET_BASE_SLOT, bytes32(uint256(uint160(assets_[0]))));
        vm.stopPrank();
    }

    function _storeControllerBucket(bytes32 namespace, address token, uint256 amount) internal {
        vm.prank(address(controller));
        kernel.updateState(_amountSlot(namespace, token), bytes32(amount));
    }

    function _protocolCut(uint256 grossAmount) internal pure returns (uint256) {
        uint256 product = grossAmount * AUCTION_FEE_BPS;
        uint256 result = product / BPS;
        if (product % BPS != 0) ++result;
        return result;
    }

    function _seedAssets(Kernel targetKernel, address[] memory assets_) internal {
        targetKernel.updateState(ASSET_COUNT_SLOT, bytes32(assets_.length));
        for (uint256 i = 0; i < assets_.length;) {
            targetKernel.updateState(_slotOffset(ASSET_BASE_SLOT, i), bytes32(uint256(uint160(assets_[i]))));
            unchecked {
                ++i;
            }
        }
    }

    function _seedBucket(Kernel targetKernel, bytes32 namespace, address token, uint256 amount) internal {
        targetKernel.updateState(_amountSlot(namespace, token), bytes32(amount));
    }

    function _storeBucket(Kernel targetKernel, bytes32 namespace, address token, uint256 amount) internal {
        vm.store(address(targetKernel), _amountSlot(namespace, token), bytes32(amount));
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
