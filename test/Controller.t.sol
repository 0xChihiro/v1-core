///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Controller} from "../src/Controller.sol";
import {EntenToken} from "../src/EntenToken.sol";
import {Kernel} from "../src/Kernel.sol";
import {Module} from "../src/Module.sol";
import {Policy} from "../src/Policy.sol";
import {Vault} from "../src/Vault.sol";
import {IController} from "../src/interfaces/IController.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {Slots} from "../src/libraries/Slots.sol";
import {Actions, InvalidKeycode, Keycode, Permissions, TargetNotAContract} from "../src/Utils.sol";
import {ERC20Mock} from "openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

contract SettlementTestModule is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("SETTL"));
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    function settle(IController.Settlement[] calldata settlements) external {
        CONTROLLER.settle(settlements);
    }

    function rawSettle(bytes calldata data) external {
        (bool success, bytes memory returnData) = address(CONTROLLER).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}

contract AuxiliaryTestModule is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("AUXIL"));
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }
}

error MockInitRevert();

contract LifecycleModuleV1 is Module {
    uint256 public initCount;

    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("LIFEC"));
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    function INIT() external override onlyController {
        ++initCount;
    }

    function restrictedPing() external view permissioned returns (uint256) {
        return 1;
    }
}

contract LifecycleModuleV2 is Module {
    uint256 public initCount;

    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("LIFEC"));
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (2, 0);
    }

    function INIT() external override onlyController {
        ++initCount;
    }

    function restrictedPing() external view permissioned returns (uint256) {
        return 2;
    }
}

contract RevertingInstallModule is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("REVER"));
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }

    function INIT() external view override onlyController {
        revert MockInitRevert();
    }
}

contract RevertingLifecycleModuleV2 is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("LIFEC"));
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (2, 0);
    }

    function INIT() external view override onlyController {
        revert MockInitRevert();
    }
}

contract InvalidKeycodeModule is Module {
    constructor(address controller) Module(controller) {}

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("badxx"));
    }

    function VERSION() external pure override returns (uint8 major, uint8 minor) {
        return (1, 0);
    }
}

contract LifecyclePolicy is Policy {
    uint256 public configureCount;
    Keycode[] internal dependencies;
    Permissions[] internal permissionRequests;

    constructor(address controller, Keycode dependency, Keycode permissionKeycode, bytes4 selector) Policy(controller) {
        dependencies.push(dependency);
        permissionRequests.push(Permissions({keycode: permissionKeycode, funcSelector: selector}));
    }

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("POLCY"));
    }

    function configureDependencies() external override returns (Keycode[] memory) {
        ++configureCount;
        return dependencies;
    }

    function requestPermissions() external view override returns (Permissions[] memory) {
        return permissionRequests;
    }

    function callRestrictedModule() external view returns (uint256) {
        Keycode keycode = permissionRequests[0].keycode;
        return LifecycleModuleV1(getModuleAddress(keycode)).restrictedPing();
    }
}

contract DuplicateDependencyPolicy is Policy {
    Keycode internal dependency;
    Permissions[] internal permissionRequests;

    constructor(address controller, Keycode dependency_, bytes4 selector) Policy(controller) {
        dependency = dependency_;
        permissionRequests.push(Permissions({keycode: dependency_, funcSelector: selector}));
    }

    function KEYCODE() public pure override returns (Keycode) {
        return Keycode.wrap(bytes5("DUPDP"));
    }

    function configureDependencies() external view override returns (Keycode[] memory dependencies) {
        dependencies = new Keycode[](2);
        dependencies[0] = dependency;
        dependencies[1] = dependency;
    }

    function requestPermissions() external view override returns (Permissions[] memory) {
        return permissionRequests;
    }
}

contract ControllerTest is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000 ether;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant AUCTION_FEE_BPS = 250;

    event ActionExecuted(Actions indexed action, address indexed target);
    event PermissionUpdated(Keycode indexed module, Keycode indexed policy, bytes4 indexed selector, bool granted);
    event MintPermissionUpdated(Keycode indexed module, bool allowed);

    Controller controller;
    Kernel kernel;
    Vault vault;
    EntenToken token;
    SettlementTestModule module;
    ERC20Mock asset;
    ERC20Mock secondAsset;

    address admin = makeAddr("Admin");
    address user = makeAddr("User");
    address creditor = makeAddr("Creditor");
    address protocolCollector = makeAddr("Protocol Collector");

    struct RawStateUpdate {
        uint8 op;
        bytes32 slot;
        bytes32 data;
    }

    struct RawSettlement {
        address payer;
        uint256 amount;
        uint8 transition;
        IController.Receipt[] receipts;
        RawStateUpdate[] singleStateUpdates;
        IController.StateUpdates[] multiStateUpdates;
    }

    struct SystemState {
        uint256 vaultAssetBalance;
        uint256 userAssetBalance;
        uint256 protocolCollectorAssetBalance;
        uint256 vaultSecondAssetBalance;
        uint256 userSecondAssetBalance;
        uint256 vaultTokenBalance;
        uint256 userTokenBalance;
        uint256 tokenSupply;
        uint256 redeem;
        uint256 borrow;
        uint256 treasury;
        uint256 team;
        uint256 collateral;
        uint256 secondRedeem;
        uint256 secondBorrow;
        uint256 rawSlotOne;
        uint256 rawSlotTwo;
    }

    function setUp() public {
        uint256 nonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedToken = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedController = vm.computeCreateAddress(address(this), nonce + 3);

        kernel = new Kernel(predictedController, predictedVault);
        vault = new Vault(predictedController, predictedKernel);
        token = new EntenToken("Enten", "ENTEN", predictedController, user, INITIAL_SUPPLY, type(uint256).max);
        controller = new Controller(admin, protocolCollector, predictedKernel, predictedVault, predictedToken);

        module = new SettlementTestModule(address(controller));
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(module));

        _setAssets(address(asset));
    }

    function testConstructorSetsImmutablesAndRoles() public view {
        assertEq(address(controller.KERNEL()), address(kernel));
        assertEq(address(controller.VAULT()), address(vault));
        assertEq(address(controller.TOKEN()), address(token));
        assertEq(controller.PROTOCOL_COLLECTOR(), protocolCollector);
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(controller.hasRole(controller.EXECUTOR_ROLE(), admin));
        assertTrue(controller.hasRole(controller.MINT_PERMISSION_ROLE(), admin));
        assertFalse(controller.hasRole(controller.CREDITOR_ROLE(), admin));
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(IController.Controller__ZeroAddress.selector);
        new Controller(address(0), protocolCollector, address(kernel), address(vault), address(token));

        vm.expectRevert(IController.Controller__ZeroAddress.selector);
        new Controller(admin, address(0), address(kernel), address(vault), address(token));

        vm.expectRevert(IController.Controller__ZeroAddress.selector);
        new Controller(admin, protocolCollector, address(0), address(vault), address(token));

        vm.expectRevert(IController.Controller__ZeroAddress.selector);
        new Controller(admin, protocolCollector, address(kernel), address(0), address(token));

        vm.expectRevert(IController.Controller__ZeroAddress.selector);
        new Controller(admin, protocolCollector, address(kernel), address(vault), address(0));
    }

    function testConstructorRejectsNonContractKernelVaultOrToken() public {
        address notContract = makeAddr("Not Contract");

        vm.expectRevert(abi.encodeWithSelector(IController.Controller__TargetNotAContract.selector, notContract));
        new Controller(admin, protocolCollector, notContract, address(vault), address(token));

        vm.expectRevert(abi.encodeWithSelector(IController.Controller__TargetNotAContract.selector, notContract));
        new Controller(admin, protocolCollector, address(kernel), notContract, address(token));

        vm.expectRevert(abi.encodeWithSelector(IController.Controller__TargetNotAContract.selector, notContract));
        new Controller(admin, protocolCollector, address(kernel), address(vault), notContract);
    }

    function testLifecycleActionsRequireExecutorAndMintPermissionRequiresMintRole() public {
        AuxiliaryTestModule auxiliaryModule = new AuxiliaryTestModule(address(controller));
        Keycode auxiliaryKeycode = auxiliaryModule.KEYCODE();
        Keycode moduleKeycode = module.KEYCODE();
        address executorOnly = makeAddr("Executor Only");
        address mintManager = makeAddr("Mint Manager");

        vm.startPrank(admin);
        controller.grantRole(controller.EXECUTOR_ROLE(), executorOnly);
        controller.grantRole(controller.MINT_PERMISSION_ROLE(), mintManager);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert();
        controller.executeAction(Actions.InstallModule, address(auxiliaryModule));

        assertEq(controller.getModuleForKeycode(auxiliaryKeycode), address(0));

        vm.prank(executorOnly);
        controller.executeAction(Actions.InstallModule, address(auxiliaryModule));

        assertEq(controller.getModuleForKeycode(auxiliaryKeycode), address(auxiliaryModule));
        assertEq(Keycode.unwrap(controller.getKeycodeForModule(auxiliaryModule)), Keycode.unwrap(auxiliaryKeycode));

        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));

        vm.prank(mintManager);
        vm.expectRevert();
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.prank(user);
        vm.expectRevert();
        controller.setMintPermission(moduleKeycode, true);

        vm.prank(executorOnly);
        vm.expectRevert();
        controller.setMintPermission(moduleKeycode, true);

        assertFalse(controller.mintPermissions(moduleKeycode));

        vm.prank(mintManager);
        controller.setMintPermission(moduleKeycode, true);

        assertTrue(controller.mintPermissions(moduleKeycode));
    }

    function testSetMintPermissionEmitsEvent() public {
        Keycode moduleKeycode = module.KEYCODE();

        vm.expectEmit(true, false, false, true, address(controller));
        emit MintPermissionUpdated(moduleKeycode, true);

        vm.prank(admin);
        controller.setMintPermission(moduleKeycode, true);

        vm.expectEmit(true, false, false, true, address(controller));
        emit MintPermissionUpdated(moduleKeycode, false);

        vm.prank(admin);
        controller.setMintPermission(moduleKeycode, false);
    }

    function testExecuteActionEmitsModuleLifecycleEvents() public {
        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        LifecycleModuleV2 upgradedModule = new LifecycleModuleV2(address(controller));

        vm.expectEmit(true, true, false, true, address(controller));
        emit ActionExecuted(Actions.InstallModule, address(lifecycleModule));

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.expectEmit(true, true, false, true, address(controller));
        emit ActionExecuted(Actions.UpgradeModule, address(upgradedModule));

        vm.prank(admin);
        controller.executeAction(Actions.UpgradeModule, address(upgradedModule));
    }

    function testExecuteActionEmitsPolicyLifecycleAndPermissionEvents() public {
        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();
        LifecyclePolicy policy = new LifecyclePolicy(
            address(controller), lifecycleKeycode, lifecycleKeycode, LifecycleModuleV1.restrictedPing.selector
        );
        Keycode policyKeycode = policy.KEYCODE();

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.expectEmit(true, true, true, true, address(controller));
        emit PermissionUpdated(lifecycleKeycode, policyKeycode, LifecycleModuleV1.restrictedPing.selector, true);
        vm.expectEmit(true, true, false, true, address(controller));
        emit ActionExecuted(Actions.ActivatePolicy, address(policy));

        vm.prank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(policy));

        vm.expectEmit(true, true, true, true, address(controller));
        emit PermissionUpdated(lifecycleKeycode, policyKeycode, LifecycleModuleV1.restrictedPing.selector, false);
        vm.expectEmit(true, true, false, true, address(controller));
        emit ActionExecuted(Actions.DeactivatePolicy, address(policy));

        vm.prank(admin);
        controller.executeAction(Actions.DeactivatePolicy, address(policy));
    }

    function testOnlyCreditorCanCallCreditCreditsAndSync() public {
        IVault.CreditCall[] memory emptyCreditCalls = new IVault.CreditCall[](0);

        vm.prank(user);
        vm.expectRevert();
        controller.credit(address(asset), 1, IVault.Bucket.Team, IVault.Bucket.Treasury);

        vm.prank(user);
        vm.expectRevert();
        controller.credits(emptyCreditCalls);

        vm.prank(user);
        vm.expectRevert();
        controller.sync(address(asset), IVault.Bucket.Redeem);

        _setBucket(IVault.Bucket.Treasury, address(asset), 30 ether);

        bytes32 creditorRole = controller.CREDITOR_ROLE();
        vm.prank(admin);
        controller.grantRole(creditorRole, creditor);

        vm.prank(creditor);
        controller.credit(address(asset), 10 ether, IVault.Bucket.Team, IVault.Bucket.Treasury);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 20 ether);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 10 ether);

        IVault.CreditCall[] memory creditCalls = new IVault.CreditCall[](1);
        creditCalls[0] = IVault.CreditCall({
            from: IVault.Bucket.Team, to: IVault.Bucket.Treasury, asset: address(asset), amount: 4 ether
        });

        vm.prank(creditor);
        controller.credits(creditCalls);

        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 24 ether);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 6 ether);

        asset.mint(address(vault), 100 ether);

        vm.prank(creditor);
        controller.sync(address(asset), IVault.Bucket.Redeem);

        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 70 ether);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 24 ether);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 6 ether);
    }

    function testExecuteActionInstallsModuleAndInitializesIt() public {
        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        assertEq(controller.getModuleForKeycode(lifecycleKeycode), address(lifecycleModule));
        assertEq(Keycode.unwrap(controller.getKeycodeForModule(lifecycleModule)), Keycode.unwrap(lifecycleKeycode));
        assertEq(Keycode.unwrap(controller.allKeycodes(1)), Keycode.unwrap(lifecycleKeycode));
        assertEq(lifecycleModule.initCount(), 1);
    }

    function testExecuteActionRejectsInvalidModuleInstallTargets() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TargetNotAContract.selector, user));
        controller.executeAction(Actions.InstallModule, user);

        InvalidKeycodeModule invalidKeycodeModule = new InvalidKeycodeModule(address(controller));
        Keycode invalidKeycode = invalidKeycodeModule.KEYCODE();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidKeycode.selector, invalidKeycode));
        controller.executeAction(Actions.InstallModule, address(invalidKeycodeModule));

        assertEq(controller.getModuleForKeycode(invalidKeycode), address(0));

        RevertingInstallModule revertingModule = new RevertingInstallModule(address(controller));
        Keycode revertingKeycode = revertingModule.KEYCODE();

        vm.prank(admin);
        vm.expectRevert(MockInitRevert.selector);
        controller.executeAction(Actions.InstallModule, address(revertingModule));

        assertEq(controller.getModuleForKeycode(revertingKeycode), address(0));
        assertEq(Keycode.unwrap(controller.getKeycodeForModule(revertingModule)), bytes5(0));
    }

    function testExecuteActionRejectsDuplicateModuleInstall() public {
        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        LifecycleModuleV2 duplicateModule = new LifecycleModuleV2(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IController.Controller__ModuleAlreadyInstalled.selector, lifecycleKeycode)
        );
        controller.executeAction(Actions.InstallModule, address(duplicateModule));

        assertEq(controller.getModuleForKeycode(lifecycleKeycode), address(lifecycleModule));
        assertEq(Keycode.unwrap(controller.getKeycodeForModule(duplicateModule)), bytes5(0));
        assertEq(duplicateModule.initCount(), 0);
    }

    function testExecuteActionUpgradesModuleAndReconfiguresDependents() public {
        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        LifecycleModuleV2 upgradedModule = new LifecycleModuleV2(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();
        LifecyclePolicy policy = new LifecyclePolicy(
            address(controller), lifecycleKeycode, lifecycleKeycode, LifecycleModuleV1.restrictedPing.selector
        );

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.prank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(policy));

        assertEq(policy.configureCount(), 1);
        assertEq(policy.callRestrictedModule(), 1);

        vm.prank(admin);
        controller.executeAction(Actions.UpgradeModule, address(upgradedModule));

        assertEq(controller.getModuleForKeycode(lifecycleKeycode), address(upgradedModule));
        assertEq(Keycode.unwrap(controller.getKeycodeForModule(lifecycleModule)), bytes5(0));
        assertEq(Keycode.unwrap(controller.getKeycodeForModule(upgradedModule)), Keycode.unwrap(lifecycleKeycode));
        assertEq(Keycode.unwrap(controller.allKeycodes(1)), Keycode.unwrap(lifecycleKeycode));
        vm.expectRevert();
        controller.allKeycodes(2);
        assertEq(upgradedModule.initCount(), 1);
        assertEq(policy.configureCount(), 2);
        assertEq(policy.callRestrictedModule(), 2);
    }

    function testExecuteActionRejectsInvalidModuleUpgrades() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TargetNotAContract.selector, user));
        controller.executeAction(Actions.UpgradeModule, user);

        InvalidKeycodeModule invalidKeycodeModule = new InvalidKeycodeModule(address(controller));
        Keycode invalidKeycode = invalidKeycodeModule.KEYCODE();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidKeycode.selector, invalidKeycode));
        controller.executeAction(Actions.UpgradeModule, address(invalidKeycodeModule));

        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IController.Controller__InvalidModuleUpgrade.selector, lifecycleKeycode));
        controller.executeAction(Actions.UpgradeModule, address(lifecycleModule));

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IController.Controller__InvalidModuleUpgrade.selector, lifecycleKeycode));
        controller.executeAction(Actions.UpgradeModule, address(lifecycleModule));

        RevertingLifecycleModuleV2 revertingUpgrade = new RevertingLifecycleModuleV2(address(controller));

        vm.prank(admin);
        vm.expectRevert(MockInitRevert.selector);
        controller.executeAction(Actions.UpgradeModule, address(revertingUpgrade));

        assertEq(controller.getModuleForKeycode(lifecycleKeycode), address(lifecycleModule));
        assertEq(Keycode.unwrap(controller.getKeycodeForModule(lifecycleModule)), Keycode.unwrap(lifecycleKeycode));
        assertEq(Keycode.unwrap(controller.getKeycodeForModule(revertingUpgrade)), bytes5(0));
    }

    function testExecuteActionActivatesPolicyAndGrantsPermissions() public {
        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();
        LifecyclePolicy policy = new LifecyclePolicy(
            address(controller), lifecycleKeycode, lifecycleKeycode, LifecycleModuleV1.restrictedPing.selector
        );

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(policy)));
        policy.callRestrictedModule();

        vm.prank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(policy));

        assertTrue(controller.isPolicyActive(address(policy)));
        assertEq(address(controller.activePolicies(0)), address(policy));
        assertEq(controller.getPolicyIndex(policy), 0);
        assertEq(address(controller.moduleDependents(lifecycleKeycode, 0)), address(policy));
        assertEq(controller.getDependentIndex(lifecycleKeycode, policy), 0);
        assertTrue(
            controller.modulePermissions(lifecycleKeycode, address(policy), LifecycleModuleV1.restrictedPing.selector)
        );
        assertEq(policy.configureCount(), 1);
        assertEq(policy.callRestrictedModule(), 1);
    }

    function testExecuteActionRejectsInvalidPolicyActivation() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TargetNotAContract.selector, user));
        controller.executeAction(Actions.ActivatePolicy, user);

        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();
        LifecyclePolicy policy = new LifecyclePolicy(
            address(controller), lifecycleKeycode, lifecycleKeycode, LifecycleModuleV1.restrictedPing.selector
        );

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.prank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(policy));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IController.Controller__PolicyAlreadyActivated.selector, address(policy))
        );
        controller.executeAction(Actions.ActivatePolicy, address(policy));

        Keycode missingKeycode = Keycode.wrap(bytes5("MISSN"));
        LifecyclePolicy missingPermissionPolicy = new LifecyclePolicy(
            address(controller), lifecycleKeycode, missingKeycode, LifecycleModuleV1.restrictedPing.selector
        );

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IController.Controller__ModuleNotInstalled.selector, missingKeycode));
        controller.executeAction(Actions.ActivatePolicy, address(missingPermissionPolicy));

        assertFalse(controller.isPolicyActive(address(missingPermissionPolicy)));
        assertFalse(
            controller.modulePermissions(
                missingKeycode, address(missingPermissionPolicy), LifecycleModuleV1.restrictedPing.selector
            )
        );
        assertEq(missingPermissionPolicy.configureCount(), 0);
    }

    function testExecuteActionRejectsDuplicatePolicyDependencies() public {
        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();
        DuplicateDependencyPolicy policy = new DuplicateDependencyPolicy(
            address(controller), lifecycleKeycode, LifecycleModuleV1.restrictedPing.selector
        );

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IController.Controller__DuplicateDependency.selector, lifecycleKeycode));
        controller.executeAction(Actions.ActivatePolicy, address(policy));

        assertFalse(controller.isPolicyActive(address(policy)));
        assertFalse(
            controller.modulePermissions(lifecycleKeycode, address(policy), LifecycleModuleV1.restrictedPing.selector)
        );

        vm.expectRevert();
        controller.activePolicies(0);

        vm.expectRevert();
        controller.moduleDependents(lifecycleKeycode, 0);
    }

    function testExecuteActionRejectsUninstalledPolicyDependency() public {
        Keycode missingKeycode = Keycode.wrap(bytes5("MISSN"));
        LifecyclePolicy policy = new LifecyclePolicy(
            address(controller), missingKeycode, module.KEYCODE(), LifecycleModuleV1.restrictedPing.selector
        );

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IController.Controller__ModuleNotInstalled.selector, missingKeycode));
        controller.executeAction(Actions.ActivatePolicy, address(policy));

        assertFalse(controller.isPolicyActive(address(policy)));
        assertFalse(
            controller.modulePermissions(module.KEYCODE(), address(policy), LifecycleModuleV1.restrictedPing.selector)
        );
        assertEq(policy.configureCount(), 0);

        vm.expectRevert();
        controller.activePolicies(0);

        vm.expectRevert();
        controller.moduleDependents(missingKeycode, 0);
    }

    function testExecuteActionDeactivatesPolicyAndRevokesPermissions() public {
        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();
        LifecyclePolicy policy = new LifecyclePolicy(
            address(controller), lifecycleKeycode, lifecycleKeycode, LifecycleModuleV1.restrictedPing.selector
        );

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.prank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(policy));

        assertEq(policy.callRestrictedModule(), 1);

        vm.prank(admin);
        controller.executeAction(Actions.DeactivatePolicy, address(policy));

        assertFalse(controller.isPolicyActive(address(policy)));
        assertFalse(
            controller.modulePermissions(lifecycleKeycode, address(policy), LifecycleModuleV1.restrictedPing.selector)
        );
        assertEq(policy.configureCount(), 2);

        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(policy)));
        policy.callRestrictedModule();

        vm.expectRevert();
        controller.activePolicies(0);

        vm.expectRevert();
        controller.moduleDependents(lifecycleKeycode, 0);
    }

    function testExecuteActionDeactivationMaintainsRemainingPolicyIndexesAndDependencies() public {
        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();
        LifecyclePolicy removedPolicy = new LifecyclePolicy(
            address(controller), lifecycleKeycode, lifecycleKeycode, LifecycleModuleV1.restrictedPing.selector
        );
        LifecyclePolicy remainingPolicy = new LifecyclePolicy(
            address(controller), lifecycleKeycode, lifecycleKeycode, LifecycleModuleV1.restrictedPing.selector
        );

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.prank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(removedPolicy));

        vm.prank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(remainingPolicy));

        assertEq(controller.getPolicyIndex(removedPolicy), 0);
        assertEq(controller.getPolicyIndex(remainingPolicy), 1);
        assertEq(controller.getDependentIndex(lifecycleKeycode, removedPolicy), 0);
        assertEq(controller.getDependentIndex(lifecycleKeycode, remainingPolicy), 1);

        vm.prank(admin);
        controller.executeAction(Actions.DeactivatePolicy, address(removedPolicy));

        assertFalse(controller.isPolicyActive(address(removedPolicy)));
        assertTrue(controller.isPolicyActive(address(remainingPolicy)));
        assertEq(address(controller.activePolicies(0)), address(remainingPolicy));
        assertEq(controller.getPolicyIndex(remainingPolicy), 0);
        assertEq(address(controller.moduleDependents(lifecycleKeycode, 0)), address(remainingPolicy));
        assertEq(controller.getDependentIndex(lifecycleKeycode, remainingPolicy), 0);
        assertFalse(
            controller.modulePermissions(
                lifecycleKeycode, address(removedPolicy), LifecycleModuleV1.restrictedPing.selector
            )
        );
        assertTrue(
            controller.modulePermissions(
                lifecycleKeycode, address(remainingPolicy), LifecycleModuleV1.restrictedPing.selector
            )
        );
        assertEq(removedPolicy.configureCount(), 2);
        assertEq(remainingPolicy.configureCount(), 1);

        vm.expectRevert(abi.encodeWithSelector(Module.Module__PolicyNotPermitted.selector, address(removedPolicy)));
        removedPolicy.callRestrictedModule();
        assertEq(remainingPolicy.callRestrictedModule(), 1);

        vm.expectRevert();
        controller.activePolicies(1);

        vm.expectRevert();
        controller.moduleDependents(lifecycleKeycode, 1);
    }

    function testExecuteActionRejectsInvalidPolicyDeactivation() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TargetNotAContract.selector, user));
        controller.executeAction(Actions.DeactivatePolicy, user);

        LifecycleModuleV1 lifecycleModule = new LifecycleModuleV1(address(controller));
        Keycode lifecycleKeycode = lifecycleModule.KEYCODE();
        LifecyclePolicy policy = new LifecyclePolicy(
            address(controller), lifecycleKeycode, lifecycleKeycode, LifecycleModuleV1.restrictedPing.selector
        );

        vm.prank(admin);
        controller.executeAction(Actions.InstallModule, address(lifecycleModule));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IController.Controller__PolicyNotActivated.selector, address(policy)));
        controller.executeAction(Actions.DeactivatePolicy, address(policy));

        vm.prank(admin);
        controller.executeAction(Actions.ActivatePolicy, address(policy));

        vm.prank(user);
        vm.expectRevert();
        controller.executeAction(Actions.DeactivatePolicy, address(policy));

        assertTrue(controller.isPolicyActive(address(policy)));
        assertTrue(
            controller.modulePermissions(lifecycleKeycode, address(policy), LifecycleModuleV1.restrictedPing.selector)
        );
        assertEq(policy.callRestrictedModule(), 1);
    }

    function testSettleBorrowSendsBackingAndMovesRedeemToBorrow() public {
        _seedBacking(100 ether);

        module.settle(_singleSettlement(IController.StateTransitions.Borrow, 0, _oneReceipt(address(asset), 40 ether)));

        assertEq(asset.balanceOf(address(vault)), 60 ether);
        assertEq(asset.balanceOf(user), 40 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 60 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 40 ether);
    }

    function testSettleRepayReceivesBackingAndMovesBorrowToRedeem() public {
        asset.mint(user, 40 ether);
        _setBucket(IVault.Bucket.Borrow, address(asset), 40 ether);

        vm.prank(user);
        asset.approve(address(vault), 40 ether);

        module.settle(_singleSettlement(IController.StateTransitions.Repay, 0, _oneReceipt(address(asset), 40 ether)));

        assertEq(asset.balanceOf(address(vault)), 40 ether);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 40 ether);
    }

    function testSettleRedeemBurnsTokenAndSendsBacking() public {
        _seedBacking(INITIAL_SUPPLY);

        module.settle(
            _singleSettlement(IController.StateTransitions.Redeem, 30 ether, _oneReceipt(address(asset), 30 ether))
        );

        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 30 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 30 ether);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY - 30 ether);
        assertEq(asset.balanceOf(user), 30 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY - 30 ether);
    }

    function testSettlePaymentReceivesAssetsCreditsBucketsAndMintsToken() public {
        _seedBacking(INITIAL_SUPPLY);
        _setRawSlot(Slots.TEAM_PERCENTAGE_SLOT, bytes32(uint256(1_000)));
        _setRawSlot(Slots.TREASURY_PERCENTAGE_SLOT, bytes32(uint256(2_000)));
        uint256 paymentAmount = 400 ether;
        uint256 mintAmount = 273 ether;
        asset.mint(user, paymentAmount);

        vm.prank(user);
        asset.approve(address(vault), paymentAmount);

        Keycode moduleKeycode = module.KEYCODE();
        vm.prank(admin);
        controller.setMintPermission(moduleKeycode, true);

        module.settle(
            _singleSettlement(
                IController.StateTransitions.Payment, mintAmount, _oneReceipt(address(asset), paymentAmount)
            )
        );

        uint256 protocolFee = _mulDivUp(paymentAmount, AUCTION_FEE_BPS, BPS);
        uint256 netAmount = paymentAmount - protocolFee;
        uint256 teamAmount = netAmount * 1_000 / BPS;
        uint256 treasuryAmount = netAmount * 2_000 / BPS;
        uint256 backingAmount = netAmount - teamAmount - treasuryAmount;

        assertEq(token.balanceOf(user), INITIAL_SUPPLY + mintAmount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + mintAmount);
        assertEq(asset.balanceOf(user), 0);
        assertEq(asset.balanceOf(protocolCollector), protocolFee);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + netAmount);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY + backingAmount);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), treasuryAmount);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), teamAmount);
    }

    function testSettleDeploySendsTreasuryAssets() public {
        _seedBacking(INITIAL_SUPPLY);
        _seedTreasury(70 ether);

        module.settle(_singleSettlement(IController.StateTransitions.Deploy, 0, _oneReceipt(address(asset), 25 ether)));

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + 45 ether);
        assertEq(asset.balanceOf(user), 25 ether);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 45 ether);
    }

    function testSettleRecallReceivesTreasuryAssets() public {
        _seedBacking(INITIAL_SUPPLY);
        asset.mint(user, 40 ether);

        vm.prank(user);
        asset.approve(address(vault), 40 ether);

        module.settle(_singleSettlement(IController.StateTransitions.Recall, 0, _oneReceipt(address(asset), 40 ether)));

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + 40 ether);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 40 ether);
    }

    function testSettleClaimSendsTeamAssets() public {
        _seedBacking(INITIAL_SUPPLY);
        _seedTeam(50 ether);

        module.settle(_singleSettlement(IController.StateTransitions.Claim, 0, _oneReceipt(address(asset), 20 ether)));

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + 30 ether);
        assertEq(asset.balanceOf(user), 20 ether);
        assertEq(_bucketValue(IVault.Bucket.Team, address(asset)), 30 ether);
    }

    function testSettleDepositSendsBackingAndReceivesTokenCollateral() public {
        _seedBacking(INITIAL_SUPPLY);

        vm.prank(user);
        token.approve(address(vault), 25 ether);

        module.settle(
            _singleSettlement(IController.StateTransitions.Deposit, 25 ether, _oneReceipt(address(asset), 45 ether))
        );

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY - 45 ether);
        assertEq(asset.balanceOf(user), 45 ether);
        assertEq(token.balanceOf(address(vault)), 25 ether);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 25 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY - 45 ether);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 45 ether);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 25 ether);
    }

    function testSettleWithdrawReceivesBackingAndSendsTokenCollateral() public {
        asset.mint(user, 45 ether);
        _setBucket(IVault.Bucket.Redeem, address(asset), INITIAL_SUPPLY - 45 ether);
        _setBucket(IVault.Bucket.Borrow, address(asset), 45 ether);
        asset.mint(address(vault), INITIAL_SUPPLY - 45 ether);

        vm.prank(user);
        token.transfer(address(vault), 25 ether);
        _setBucket(IVault.Bucket.Collateral, address(token), 25 ether);

        vm.prank(user);
        asset.approve(address(vault), 45 ether);

        module.settle(
            _singleSettlement(IController.StateTransitions.Withdraw, 25 ether, _oneReceipt(address(asset), 45 ether))
        );

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY);
        assertEq(asset.balanceOf(user), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(user), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
        assertEq(_bucketValue(IVault.Bucket.Borrow, address(asset)), 0);
        assertEq(_bucketValue(IVault.Bucket.Collateral, address(token)), 0);
    }

    function testSettleBurnBurnsTokenWithoutTransfers() public {
        _seedBacking(INITIAL_SUPPLY);

        module.settle(_singleSettlement(IController.StateTransitions.Burn, 100 ether, new IController.Receipt[](0)));

        assertEq(token.balanceOf(user), INITIAL_SUPPLY - 100 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - 100 ether);
        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), INITIAL_SUPPLY);
    }

    function testSettleStateUpdateAppliesSingleAndMultiKernelUpdates() public {
        bytes32 addSubSlot = keccak256("controller.test.add-sub");
        bytes32 setSlot = keccak256("controller.test.set");
        bytes32 rangeStart = keccak256("controller.test.range");
        _setRawSlot(addSubSlot, bytes32(uint256(10)));

        IController.StateUpdate[] memory singleUpdates = new IController.StateUpdate[](3);
        singleUpdates[0] =
            IController.StateUpdate({op: IController.Op.Add, slot: addSubSlot, data: bytes32(uint256(7))});
        singleUpdates[1] =
            IController.StateUpdate({op: IController.Op.Sub, slot: addSubSlot, data: bytes32(uint256(2))});
        singleUpdates[2] = IController.StateUpdate({op: IController.Op.Set, slot: setSlot, data: bytes32(uint256(42))});

        IController.StateUpdates[] memory multiUpdates = new IController.StateUpdates[](1);
        multiUpdates[0] = IController.StateUpdates({
            startSlot: rangeStart, data: abi.encode(bytes32(uint256(1)), bytes32(uint256(2)))
        });

        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        settlements[0].singleStateUpdates = singleUpdates;
        settlements[0].multiStateUpdates = multiUpdates;

        module.settle(settlements);

        assertEq(uint256(kernel.viewData(addSubSlot)), 15);
        assertEq(uint256(kernel.viewData(setSlot)), 42);
        assertEq(uint256(kernel.viewData(rangeStart)), 1);
        assertEq(uint256(kernel.viewData(bytes32(uint256(rangeStart) + 1))), 2);
    }

    function testSettlePaymentWithoutMintPermissionRevertsAndLeavesStateUnchanged() public {
        _seedBacking(INITIAL_SUPPLY);
        asset.mint(user, 400 ether);

        vm.prank(user);
        asset.approve(address(vault), 400 ether);

        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert(IController.Controller__MintPermissionDenied.selector);
        module.settle(
            _singleSettlement(IController.StateTransitions.Payment, 273 ether, _oneReceipt(address(asset), 400 ether))
        );

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettlePaymentThatLowersBackingRevertsAndRollsBackState() public {
        _seedBacking(INITIAL_SUPPLY);
        _setRawSlot(Slots.TEAM_PERCENTAGE_SLOT, bytes32(uint256(1_000)));
        _setRawSlot(Slots.TREASURY_PERCENTAGE_SLOT, bytes32(uint256(2_000)));
        asset.mint(user, 400 ether);

        vm.prank(user);
        asset.approve(address(vault), 400 ether);

        Keycode moduleKeycode = module.KEYCODE();
        vm.prank(admin);
        controller.setMintPermission(moduleKeycode, true);

        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert(IController.Controller__BackingWentDown.selector);
        module.settle(
            _singleSettlement(IController.StateTransitions.Payment, 274 ether, _oneReceipt(address(asset), 400 ether))
        );

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettlePaymentWithOverAllocatedBpsRevertsAndLeavesStateUnchanged() public {
        _seedBacking(INITIAL_SUPPLY);
        _setRawSlot(Slots.TEAM_PERCENTAGE_SLOT, bytes32(uint256(6_000)));
        _setRawSlot(Slots.TREASURY_PERCENTAGE_SLOT, bytes32(uint256(5_000)));
        asset.mint(user, 400 ether);

        vm.prank(user);
        asset.approve(address(vault), 400 ether);

        Keycode moduleKeycode = module.KEYCODE();
        vm.prank(admin);
        controller.setMintPermission(moduleKeycode, true);

        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert();
        module.settle(
            _singleSettlement(IController.StateTransitions.Payment, 1 ether, _oneReceipt(address(asset), 400 ether))
        );

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettleBurnWithReceiptsRevertsAndLeavesStateUnchanged() public {
        _seedBacking(INITIAL_SUPPLY);

        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert(IController.Controller__TransfersDuringBurn.selector);
        module.settle(
            _singleSettlement(IController.StateTransitions.Burn, 100 ether, _oneReceipt(address(asset), 1 ether))
        );

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettleStateUpdateWithReceiptsRevertsAndLeavesStateUnchanged() public {
        bytes32 rawSlot = keccak256("controller.state-update.receipts");
        _setRawSlot(rawSlot, bytes32(uint256(10)));

        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.StateUpdate, 0, _oneReceipt(address(asset), 1 ether));
        settlements[0].singleStateUpdates = _oneStateUpdate(IController.Op.Set, rawSlot, bytes32(uint256(20)));

        SystemState memory beforeState = _snapshot(rawSlot, bytes32(0));

        vm.expectRevert(IController.Controller__StateUpdatesOnly.selector);
        module.settle(settlements);

        _assertStateUnchanged(beforeState, rawSlot, bytes32(0));
    }

    function testSettleStateUpdateWithoutUpdatesRevertsAndLeavesStateUnchanged() public {
        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert(IController.Controller__NoUpdatesGiven.selector);
        module.settle(_singleSettlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0)));

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettleInvalidStateUpdateOperationRevertsAndLeavesStateUnchanged() public {
        bytes32 rawSlot = keccak256("controller.invalid-state-op");
        _setRawSlot(rawSlot, bytes32(uint256(10)));

        RawStateUpdate[] memory singleStateUpdates = new RawStateUpdate[](1);
        singleStateUpdates[0] = RawStateUpdate({op: 3, slot: rawSlot, data: bytes32(uint256(1))});

        RawSettlement[] memory rawSettlements = new RawSettlement[](1);
        rawSettlements[0] = RawSettlement({
            payer: user,
            amount: 0,
            transition: uint8(IController.StateTransitions.StateUpdate),
            receipts: new IController.Receipt[](0),
            singleStateUpdates: singleStateUpdates,
            multiStateUpdates: new IController.StateUpdates[](0)
        });

        SystemState memory beforeState = _snapshot(rawSlot, bytes32(0));

        vm.expectRevert();
        module.rawSettle(abi.encodeWithSelector(IController.settle.selector, rawSettlements));

        _assertStateUnchanged(beforeState, rawSlot, bytes32(0));
    }

    function testSettleFromInactiveModuleRevertsAndLeavesStateUnchanged() public {
        bytes32 rawSlot = keccak256("controller.inactive-module");
        _setRawSlot(rawSlot, bytes32(uint256(10)));

        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        settlements[0].singleStateUpdates = _oneStateUpdate(IController.Op.Set, rawSlot, bytes32(uint256(20)));

        SystemState memory beforeState = _snapshot(rawSlot, bytes32(0));

        vm.expectRevert(IController.Controller__InactiveModule.selector);
        controller.settle(settlements);

        _assertStateUnchanged(beforeState, rawSlot, bytes32(0));
    }

    function testSettleVaultTransferFailureRevertsAndLeavesStateUnchanged() public {
        _seedBacking(INITIAL_SUPPLY);
        asset.mint(user, 40 ether);

        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert();
        module.settle(_singleSettlement(IController.StateTransitions.Recall, 0, _oneReceipt(address(asset), 40 ether)));

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettleTokenFailureRevertsAndLeavesStateUnchanged() public {
        _seedBacking(INITIAL_SUPPLY);

        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert();
        module.settle(
            _singleSettlement(IController.StateTransitions.Burn, INITIAL_SUPPLY + 1, new IController.Receipt[](0))
        );

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettleVaultKernelFailureRevertsAndLeavesStateUnchanged() public {
        _seedBacking(INITIAL_SUPPLY);

        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        module.settle(_singleSettlement(IController.StateTransitions.Deploy, 0, _oneReceipt(address(asset), 1 ether)));

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettleStateUpdateKernelFailureRevertsAndLeavesStateUnchanged() public {
        bytes32 rawSlot = keccak256("controller.state-update-kernel-failure");
        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        settlements[0].singleStateUpdates = _oneStateUpdate(IController.Op.Sub, rawSlot, bytes32(uint256(1)));

        SystemState memory beforeState = _snapshot(rawSlot, bytes32(0));

        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        module.settle(settlements);

        _assertStateUnchanged(beforeState, rawSlot, bytes32(0));
    }

    function testSettleStateUpdateWithZeroSupplyAndConfiguredAssetsSucceeds() public {
        vm.prank(address(controller));
        token.burnFrom(user, INITIAL_SUPPLY);

        _seedBacking(100 ether);
        bytes32 rawSlot = keccak256("controller.zero-supply-state-update");
        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        settlements[0].singleStateUpdates = _oneStateUpdate(IController.Op.Set, rawSlot, bytes32(uint256(55)));

        module.settle(settlements);

        assertEq(token.totalSupply(), 0);
        assertEq(uint256(kernel.viewData(rawSlot)), 55);
        assertEq(asset.balanceOf(address(vault)), 100 ether);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), 100 ether);
    }

    function testSettlePaymentFromZeroSupplyCanEstablishBacking() public {
        vm.prank(address(controller));
        token.burnFrom(user, INITIAL_SUPPLY);

        uint256 paymentAmount = 100 ether;
        uint256 mintAmount = 90 ether;
        asset.mint(user, paymentAmount);

        vm.prank(user);
        asset.approve(address(vault), paymentAmount);

        Keycode moduleKeycode = module.KEYCODE();
        vm.prank(admin);
        controller.setMintPermission(moduleKeycode, true);

        module.settle(
            _singleSettlement(
                IController.StateTransitions.Payment, mintAmount, _oneReceipt(address(asset), paymentAmount)
            )
        );

        uint256 protocolFee = _mulDivUp(paymentAmount, AUCTION_FEE_BPS, BPS);
        uint256 backingAmount = paymentAmount - protocolFee;

        assertEq(token.totalSupply(), mintAmount);
        assertEq(token.balanceOf(user), mintAmount);
        assertEq(asset.balanceOf(protocolCollector), protocolFee);
        assertEq(asset.balanceOf(address(vault)), backingAmount);
        assertEq(_bucketValue(IVault.Bucket.Redeem, address(asset)), backingAmount);
    }

    function testSettleBatchLaterFailureRollsBackEarlierSettlement() public {
        _seedBacking(INITIAL_SUPPLY);
        asset.mint(user, 40 ether);

        vm.prank(user);
        asset.approve(address(vault), 40 ether);

        IController.Settlement[] memory settlements = new IController.Settlement[](2);
        settlements[0] = _settlement(IController.StateTransitions.Recall, 0, _oneReceipt(address(asset), 40 ether));
        settlements[1] = _settlement(IController.StateTransitions.Deploy, 0, _oneReceipt(address(asset), 41 ether));

        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert(Kernel.Kernel__SubUnderflow.selector);
        module.settle(settlements);

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettleRevertsIfAnyAssetBackingPerTokenDecreasesEvenWhenAnotherIncreases() public {
        _setAssets(address(asset), address(secondAsset));
        _seedBacking(asset, INITIAL_SUPPLY);
        _seedBacking(secondAsset, INITIAL_SUPPLY);

        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.StateUpdate, 0, new IController.Receipt[](0));
        IController.StateUpdate[] memory updates = new IController.StateUpdate[](2);
        updates[0] = IController.StateUpdate({
            op: IController.Op.Sub,
            slot: _bucketSlot(IVault.Bucket.Redeem, address(asset)),
            data: bytes32(uint256(1 ether))
        });
        updates[1] = IController.StateUpdate({
            op: IController.Op.Add,
            slot: _bucketSlot(IVault.Bucket.Redeem, address(secondAsset)),
            data: bytes32(uint256(100 ether))
        });
        settlements[0].singleStateUpdates = updates;

        SystemState memory beforeState = _snapshot(bytes32(0), bytes32(0));

        vm.expectRevert(IController.Controller__BackingWentDown.selector);
        module.settle(settlements);

        _assertStateUnchanged(beforeState, bytes32(0), bytes32(0));
    }

    function testSettleAllowsStateUpdatesOnNonStateUpdateTransition() public {
        _seedBacking(INITIAL_SUPPLY);
        asset.mint(user, 40 ether);
        bytes32 rawSlot = keccak256("controller.recall-with-state-update");

        vm.prank(user);
        asset.approve(address(vault), 40 ether);

        IController.Settlement[] memory settlements =
            _singleSettlement(IController.StateTransitions.Recall, 0, _oneReceipt(address(asset), 40 ether));
        settlements[0].singleStateUpdates = _oneStateUpdate(IController.Op.Set, rawSlot, bytes32(uint256(99)));

        module.settle(settlements);

        assertEq(asset.balanceOf(address(vault)), INITIAL_SUPPLY + 40 ether);
        assertEq(asset.balanceOf(user), 0);
        assertEq(_bucketValue(IVault.Bucket.Treasury, address(asset)), 40 ether);
        assertEq(uint256(kernel.viewData(rawSlot)), 99);
    }

    function testSettleEmptyArrayIsNoOp() public {
        _seedBacking(INITIAL_SUPPLY);
        bytes32 rawSlot = keccak256("controller.empty-settlement-array");
        _setRawSlot(rawSlot, bytes32(uint256(10)));
        IController.Settlement[] memory settlements = new IController.Settlement[](0);

        SystemState memory beforeState = _snapshot(rawSlot, bytes32(0));

        module.settle(settlements);

        _assertStateUnchanged(beforeState, rawSlot, bytes32(0));
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
            multiStateUpdates: new IController.StateUpdates[](0)
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

    function _snapshot(bytes32 rawSlotOne, bytes32 rawSlotTwo) internal view returns (SystemState memory state) {
        state = SystemState({
            vaultAssetBalance: asset.balanceOf(address(vault)),
            userAssetBalance: asset.balanceOf(user),
            protocolCollectorAssetBalance: asset.balanceOf(protocolCollector),
            vaultSecondAssetBalance: secondAsset.balanceOf(address(vault)),
            userSecondAssetBalance: secondAsset.balanceOf(user),
            vaultTokenBalance: token.balanceOf(address(vault)),
            userTokenBalance: token.balanceOf(user),
            tokenSupply: token.totalSupply(),
            redeem: _bucketValue(IVault.Bucket.Redeem, address(asset)),
            borrow: _bucketValue(IVault.Bucket.Borrow, address(asset)),
            treasury: _bucketValue(IVault.Bucket.Treasury, address(asset)),
            team: _bucketValue(IVault.Bucket.Team, address(asset)),
            collateral: _bucketValue(IVault.Bucket.Collateral, address(token)),
            secondRedeem: _bucketValue(IVault.Bucket.Redeem, address(secondAsset)),
            secondBorrow: _bucketValue(IVault.Bucket.Borrow, address(secondAsset)),
            rawSlotOne: uint256(kernel.viewData(rawSlotOne)),
            rawSlotTwo: uint256(kernel.viewData(rawSlotTwo))
        });
    }

    function _assertStateUnchanged(SystemState memory beforeState, bytes32 rawSlotOne, bytes32 rawSlotTwo)
        internal
        view
    {
        SystemState memory afterState = _snapshot(rawSlotOne, rawSlotTwo);

        assertEq(afterState.vaultAssetBalance, beforeState.vaultAssetBalance, "vault asset balance");
        assertEq(afterState.userAssetBalance, beforeState.userAssetBalance, "user asset balance");
        assertEq(
            afterState.protocolCollectorAssetBalance,
            beforeState.protocolCollectorAssetBalance,
            "collector asset balance"
        );
        assertEq(afterState.vaultSecondAssetBalance, beforeState.vaultSecondAssetBalance, "vault second asset balance");
        assertEq(afterState.userSecondAssetBalance, beforeState.userSecondAssetBalance, "user second asset balance");
        assertEq(afterState.vaultTokenBalance, beforeState.vaultTokenBalance, "vault token balance");
        assertEq(afterState.userTokenBalance, beforeState.userTokenBalance, "user token balance");
        assertEq(afterState.tokenSupply, beforeState.tokenSupply, "token supply");
        assertEq(afterState.redeem, beforeState.redeem, "redeem bucket");
        assertEq(afterState.borrow, beforeState.borrow, "borrow bucket");
        assertEq(afterState.treasury, beforeState.treasury, "treasury bucket");
        assertEq(afterState.team, beforeState.team, "team bucket");
        assertEq(afterState.collateral, beforeState.collateral, "collateral bucket");
        assertEq(afterState.secondRedeem, beforeState.secondRedeem, "second redeem bucket");
        assertEq(afterState.secondBorrow, beforeState.secondBorrow, "second borrow bucket");
        assertEq(afterState.rawSlotOne, beforeState.rawSlotOne, "raw slot one");
        assertEq(afterState.rawSlotTwo, beforeState.rawSlotTwo, "raw slot two");
    }

    function _seedBacking(uint256 amount) internal {
        _seedBacking(asset, amount);
    }

    function _seedBacking(ERC20Mock token_, uint256 amount) internal {
        token_.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Redeem, address(token_), amount);
    }

    function _seedTreasury(uint256 amount) internal {
        asset.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Treasury, address(asset), amount);
    }

    function _seedTeam(uint256 amount) internal {
        asset.mint(address(vault), amount);
        _setBucket(IVault.Bucket.Team, address(asset), amount);
    }

    function _setAssets(address first) internal {
        address[] memory assets = new address[](1);
        assets[0] = first;
        _setAssets(assets);
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

        vm.startPrank(address(controller));
        kernel.updateState(Slots.ASSETS_LENGTH_SLOT, bytes32(assets.length));
        kernel.updateState(Slots.ASSETS_BASE_SLOT, data);
        vm.stopPrank();
    }

    function _setBucket(IVault.Bucket bucket, address token_, uint256 amount) internal {
        _setRawSlot(_bucketSlot(bucket, token_), bytes32(amount));
    }

    function _setRawSlot(bytes32 slot, bytes32 value) internal {
        vm.prank(address(controller));
        kernel.updateState(slot, value);
    }

    function _bucketValue(IVault.Bucket bucket, address token_) internal view returns (uint256) {
        return uint256(kernel.viewData(_bucketSlot(bucket, token_)));
    }

    function _bucketSlot(IVault.Bucket bucket, address token_) internal pure returns (bytes32) {
        if (bucket == IVault.Bucket.Borrow) return _slot(Slots.ASSET_TOTAL_BORROWED_BASE_SLOT, token_);
        if (bucket == IVault.Bucket.Redeem) return _slot(Slots.BACKING_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Treasury) return _slot(Slots.TREASURY_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Team) return _slot(Slots.TEAM_AMOUNT_SLOT, token_);
        if (bucket == IVault.Bucket.Collateral) return _slot(Slots.TOTAL_COLLATERL_SLOT, token_);
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
}
