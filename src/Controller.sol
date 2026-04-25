///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin/contracts/access/AccessControl.sol";
import {Kernel} from "./Kernel.sol";
import {Vault} from "./Vault.sol";
import {IController, IModule, IPolicy, Keycode, Permission} from "./interfaces/IController.sol";
import {IVault} from "./interfaces/IVault.sol";

contract Controller is IController, AccessControl {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant AUCTION_FEE_BPS = 250;
    uint256 public constant LP_FEE_BPS = 2_000;

    Kernel public immutable KERNEL;
    Vault public immutable VAULT;
    address public immutable PROTOCOL_COLLECTOR;

    Keycode[] public allModuleKeycodes;
    Keycode[] public allPolicyKeycodes;

    mapping(Keycode keycode => address module) public moduleForKeycode;
    mapping(address module => Keycode keycode) public keycodeForModule;
    mapping(Keycode keycode => bool active) public activeModules;

    mapping(Keycode keycode => address policy) public policyForKeycode;
    mapping(address policy => Keycode keycode) public keycodeForPolicy;
    mapping(Keycode keycode => bool active) public activePolicies;

    mapping(Keycode policy => Keycode[] dependencies) public policyDependencies;
    mapping(Keycode module => mapping(Keycode policy => mapping(bytes4 selector => bool allowed))) public
        policyPermissions;
    mapping(bytes4 selector => mapping(Keycode module => bool allowed)) public modulePermissions;

    struct AuctionAssetSettlement {
        address asset;
        uint256 grossAmount;
        uint256 backingAmount;
        uint256 treasuryAmount;
        uint256 teamAmount;
    }

    struct AuctionSettlement {
        address payer;
        AuctionAssetSettlement[] assets;
    }

    event ActionExecuted(Action indexed action, address indexed target);
    event ModuleInstalled(Keycode indexed keycode, address indexed module);
    event ModuleUpgraded(Keycode indexed keycode, address indexed oldModule, address indexed newModule);
    event ModuleStatusUpdated(Keycode indexed keycode, address indexed module, bool active);
    event PolicyInstalled(Keycode indexed keycode, address indexed policy);
    event PolicyUpgraded(Keycode indexed keycode, address indexed oldPolicy, address indexed newPolicy);
    event PolicyStatusUpdated(Keycode indexed keycode, address indexed policy, bool active);
    event PermissionUpdated(Keycode indexed module, Keycode indexed policy, bytes4 indexed selector, bool granted);
    event ModulePermissionUpdated(Keycode indexed module, bytes4 indexed selector, bool granted);
    event AuctionCleared(address indexed module, address indexed payer, uint256 assetCount);

    error Controller__ZeroAddress();
    error Controller__TargetNotAContract(address target);
    error Controller__InvalidKeycode(Keycode keycode);
    error Controller__ModuleAlreadyInstalled(Keycode keycode);
    error Controller__ModuleNotInstalled(Keycode keycode);
    error Controller__ModuleAlreadyActive(Keycode keycode);
    error Controller__ModuleNotActive(Keycode keycode);
    error Controller__InvalidModuleUpgrade(Keycode keycode);
    error Controller__PolicyAlreadyInstalled(Keycode keycode);
    error Controller__PolicyNotInstalled(Keycode keycode);
    error Controller__PolicyAlreadyActive(Keycode keycode);
    error Controller__PolicyNotActive(Keycode keycode);
    error Controller__InvalidPolicyUpgrade(Keycode keycode);
    error Controller__InactivePolicy();
    error Controller__InactiveModule();
    error Controller__ModulePermissionDenied();
    error Controller__InvalidAuctionSettlement();
    error Controller__InvalidSettlementAsset();
    error Controller__ProtocolCutRoundsToZero();

    constructor(address admin, address protocolCollector) {
        if (admin == address(0)) revert Controller__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);

        PROTOCOL_COLLECTOR = protocolCollector;
        KERNEL = new Kernel(address(this));
        VAULT = new Vault(address(this), address(KERNEL));
        KERNEL.setAccountingWriter(address(VAULT));
    }

    modifier onlyActivePolicy() {
        _onlyActivePolicy();
        _;
    }

    modifier onlyActiveModule() {
        _onlyActiveModule();
        _;
    }

    modifier onlyPermittedModule() {
        _onlyPermittedModule();
        _;
    }

    function execute(Action action, address target) external onlyRole(EXECUTOR_ROLE) {
        if (action == Action.InstallModule) {
            _installModule(target);
        } else if (action == Action.UpgradeModule) {
            _upgradeModule(target);
        } else if (action == Action.ActivateModule) {
            _activateModule(target);
        } else if (action == Action.InstallPolicy) {
            _installPolicy(target);
        } else if (action == Action.UpgradePolicy) {
            _upgradePolicy(target);
        } else if (action == Action.ActivatePolicy) {
            _activatePolicy(target);
        }

        emit ActionExecuted(action, target);
    }

    function moduleKeycodeAt(uint256 index) external view returns (Keycode) {
        return allModuleKeycodes[index];
    }

    function policyKeycodeAt(uint256 index) external view returns (Keycode) {
        return allPolicyKeycodes[index];
    }

    function policyDependencyAt(Keycode policy, uint256 index) external view returns (Keycode) {
        return policyDependencies[policy][index];
    }

    function setModulePermission(Keycode module, bytes4 selector, bool allowed) external onlyRole(EXECUTOR_ROLE) {
        if (moduleForKeycode[module] == address(0)) revert Controller__ModuleNotInstalled(module);
        if (!activeModules[module]) revert Controller__ModuleNotActive(module);

        modulePermissions[selector][module] = allowed;

        emit ModulePermissionUpdated(module, selector, allowed);
    }

    // function clearBorrow(BorrowSettlement calldata settlement) external onlyPermittedModule {}

    function clearAuction(AuctionSettlement calldata settlement) external onlyPermittedModule {
        if (settlement.payer == address(0)) revert Controller__ZeroAddress();

        uint256 length = settlement.assets.length;
        if (length == 0) revert Controller__InvalidAuctionSettlement();

        IVault.ReceiveCall[] memory receiveCalls = new IVault.ReceiveCall[](length);
        IVault.TreasuryCall[] memory protocolCalls = new IVault.TreasuryCall[](length);

        uint256 creditCount;
        for (uint256 i; i < length;) {
            AuctionAssetSettlement calldata assetSettlement = settlement.assets[i];

            if (assetSettlement.asset == address(0) || assetSettlement.grossAmount == 0) {
                revert Controller__InvalidSettlementAsset();
            }

            uint256 protocolCut = _mulDivUp(assetSettlement.grossAmount, AUCTION_FEE_BPS, BPS);
            if (protocolCut == 0) revert Controller__ProtocolCutRoundsToZero();

            uint256 distributable = assetSettlement.grossAmount - protocolCut;
            uint256 allocated =
                assetSettlement.backingAmount + assetSettlement.treasuryAmount + assetSettlement.teamAmount;
            if (allocated != distributable) revert Controller__InvalidAuctionSettlement();

            receiveCalls[i] = IVault.ReceiveCall({
                from: settlement.payer,
                asset: assetSettlement.asset,
                amount: assetSettlement.grossAmount,
                bucket: IVault.Bucket.Treasury
            });
            protocolCalls[i] =
                IVault.TreasuryCall({asset: assetSettlement.asset, to: PROTOCOL_COLLECTOR, amount: protocolCut});

            if (assetSettlement.backingAmount != 0) ++creditCount;
            if (assetSettlement.teamAmount != 0) ++creditCount;

            unchecked {
                ++i;
            }
        }

        IVault.CreditCall[] memory creditCalls = new IVault.CreditCall[](creditCount);
        uint256 cursor;
        for (uint256 i; i < length;) {
            AuctionAssetSettlement calldata assetSettlement = settlement.assets[i];

            if (assetSettlement.backingAmount != 0) {
                creditCalls[cursor] = IVault.CreditCall({
                    from: IVault.Bucket.Treasury,
                    to: IVault.Bucket.Backing,
                    asset: assetSettlement.asset,
                    amount: assetSettlement.backingAmount
                });
                unchecked {
                    ++cursor;
                }
            }

            if (assetSettlement.teamAmount != 0) {
                creditCalls[cursor] = IVault.CreditCall({
                    from: IVault.Bucket.Treasury,
                    to: IVault.Bucket.Team,
                    asset: assetSettlement.asset,
                    amount: assetSettlement.teamAmount
                });
                unchecked {
                    ++cursor;
                }
            }

            unchecked {
                ++i;
            }
        }

        VAULT.receiveAssets(receiveCalls);
        VAULT.transferTreasuryAssets(protocolCalls);

        if (creditCount != 0) {
            VAULT.credits(creditCalls);
        }

        emit AuctionCleared(msg.sender, settlement.payer, length);
    }

    function _installModule(address target) internal {
        _ensureContract(target);

        Keycode keycode = IModule(target).keycode();
        _ensureValidKeycode(keycode);

        if (moduleForKeycode[keycode] != address(0)) revert Controller__ModuleAlreadyInstalled(keycode);

        moduleForKeycode[keycode] = target;
        keycodeForModule[target] = keycode;
        allModuleKeycodes.push(keycode);

        IModule(target).init();

        emit ModuleInstalled(keycode, target);
    }

    function _upgradeModule(address target) internal {
        _ensureContract(target);

        Keycode keycode = IModule(target).keycode();
        _ensureValidKeycode(keycode);

        address oldModule = moduleForKeycode[keycode];
        if (oldModule == address(0) || oldModule == target) revert Controller__InvalidModuleUpgrade(keycode);

        keycodeForModule[oldModule] = Keycode.wrap(bytes5(0));
        moduleForKeycode[keycode] = target;
        keycodeForModule[target] = keycode;

        IModule(target).init();

        emit ModuleUpgraded(keycode, oldModule, target);
    }

    function _activateModule(address target) internal {
        Keycode keycode = keycodeForModule[target];
        if (_isEmptyKeycode(keycode)) revert Controller__ModuleNotInstalled(keycode);
        if (activeModules[keycode]) revert Controller__ModuleAlreadyActive(keycode);

        activeModules[keycode] = true;

        emit ModuleStatusUpdated(keycode, target, true);
    }

    function _installPolicy(address target) internal {
        _ensureContract(target);

        Keycode keycode = IPolicy(target).keycode();
        _ensureValidKeycode(keycode);

        if (policyForKeycode[keycode] != address(0)) revert Controller__PolicyAlreadyInstalled(keycode);

        policyForKeycode[keycode] = target;
        keycodeForPolicy[target] = keycode;
        allPolicyKeycodes.push(keycode);

        emit PolicyInstalled(keycode, target);
    }

    function _upgradePolicy(address target) internal {
        _ensureContract(target);

        Keycode keycode = IPolicy(target).keycode();
        _ensureValidKeycode(keycode);

        address oldPolicy = policyForKeycode[keycode];
        if (oldPolicy == address(0) || oldPolicy == target) revert Controller__InvalidPolicyUpgrade(keycode);

        bool wasActive = activePolicies[keycode];
        if (wasActive) _deactivatePolicy(oldPolicy);

        keycodeForPolicy[oldPolicy] = Keycode.wrap(bytes5(0));
        policyForKeycode[keycode] = target;
        keycodeForPolicy[target] = keycode;

        if (wasActive) _activatePolicy(target);

        emit PolicyUpgraded(keycode, oldPolicy, target);
    }

    function _activatePolicy(address target) internal {
        Keycode policyKeycode = keycodeForPolicy[target];
        if (_isEmptyKeycode(policyKeycode)) revert Controller__PolicyNotInstalled(policyKeycode);
        if (activePolicies[policyKeycode]) revert Controller__PolicyAlreadyActive(policyKeycode);

        delete policyDependencies[policyKeycode];
        Keycode[] memory dependencies = IPolicy(target).configureDependencies();
        for (uint256 i; i < dependencies.length;) {
            Keycode dependency = dependencies[i];
            if (moduleForKeycode[dependency] == address(0)) revert Controller__ModuleNotInstalled(dependency);
            if (!activeModules[dependency]) revert Controller__ModuleNotActive(dependency);
            policyDependencies[policyKeycode].push(dependency);
            unchecked {
                ++i;
            }
        }

        Permission[] memory requests = IPolicy(target).requestPermissions();
        _setPolicyPermissions(policyKeycode, requests, true);
        activePolicies[policyKeycode] = true;

        emit PolicyStatusUpdated(policyKeycode, target, true);
    }

    function _deactivatePolicy(address target) internal {
        Keycode policyKeycode = keycodeForPolicy[target];
        if (_isEmptyKeycode(policyKeycode)) revert Controller__PolicyNotInstalled(policyKeycode);
        if (!activePolicies[policyKeycode]) revert Controller__PolicyNotActive(policyKeycode);

        Permission[] memory requests = IPolicy(target).requestPermissions();
        _setPolicyPermissions(policyKeycode, requests, false);

        delete policyDependencies[policyKeycode];
        activePolicies[policyKeycode] = false;

        emit PolicyStatusUpdated(policyKeycode, target, false);
    }

    function _setPolicyPermissions(Keycode policyKeycode, Permission[] memory requests, bool granted) internal {
        for (uint256 i; i < requests.length;) {
            Permission memory request = requests[i];
            if (moduleForKeycode[request.keycode] == address(0)) {
                revert Controller__ModuleNotInstalled(request.keycode);
            }
            if (!activeModules[request.keycode]) revert Controller__ModuleNotActive(request.keycode);

            policyPermissions[request.keycode][policyKeycode][request.selector] = granted;

            emit PermissionUpdated(request.keycode, policyKeycode, request.selector, granted);

            unchecked {
                ++i;
            }
        }
    }

    function _onlyActivePolicy() internal view {
        Keycode keycode = keycodeForPolicy[msg.sender];
        if (_isEmptyKeycode(keycode) || !activePolicies[keycode]) revert Controller__InactivePolicy();
    }

    function _onlyActiveModule() internal view {
        Keycode keycode = keycodeForModule[msg.sender];
        if (_isEmptyKeycode(keycode) || !activeModules[keycode]) revert Controller__InactiveModule();
    }

    function _onlyPermittedModule() internal view {
        Keycode keycode = keycodeForModule[msg.sender];
        if (_isEmptyKeycode(keycode) || !activeModules[keycode]) revert Controller__InactiveModule();
        if (!modulePermissions[msg.sig][keycode]) revert Controller__ModulePermissionDenied();
    }

    function _ensureContract(address target) internal view {
        if (target.code.length == 0) revert Controller__TargetNotAContract(target);
    }

    function _ensureValidKeycode(Keycode keycode) internal pure {
        bytes5 raw = Keycode.unwrap(keycode);
        for (uint256 i; i < 5;) {
            bytes1 char = raw[i];
            if (char < 0x41 || char > 0x5A) revert Controller__InvalidKeycode(keycode);
            unchecked {
                ++i;
            }
        }
    }

    function _isEmptyKeycode(Keycode keycode) internal pure returns (bool) {
        return Keycode.unwrap(keycode) == bytes5(0);
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
