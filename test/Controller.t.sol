///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin/access/IAccessControl.sol";
import {Controller} from "../src/Controller.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {IAuctionFactory} from "../src/interfaces/factories/IAuctionFactory.sol";
import {IControllerFactory} from "../src/interfaces/factories/IControllerFactory.sol";
import {ITokenFactory} from "../src/interfaces/factories/ITokenFactory.sol";
import {ITreasuryFactory} from "../src/interfaces/factories/ITreasuryFactory.sol";
import {IBorrowerFactory} from "../src/interfaces/factories/IBorrowerFactory.sol";

contract MockControllerToken {
    address public borrower;
    uint256 public totalSupply;
    uint256 public constant MAX_SUPPLY = type(uint256).max;

    mapping(address => bool) private _knownAssets;
    address[] private _assets;

    function addBorrower(address account) external {
        borrower = account;
    }

    function addAsset(address asset) external {
        if (_knownAssets[asset]) return;
        _knownAssets[asset] = true;
        _assets.push(asset);
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }
}

contract MockTokenFactory is ITokenFactory {
    address public immutable token;
    TokenConfig public lastConfig;

    constructor(address token_) {
        token = token_;
    }

    function createToken(TokenConfig memory config) external returns (address) {
        lastConfig = config;
        return token;
    }
}

contract MockAuction {
    uint256 public constant LOT_SIZE = 1e18;
    bool public started;

    function start() external {
        started = true;
    }
}

contract MockAuctionFactory is IAuctionFactory {
    address public immutable auction;
    address public lastController;
    address public lastToken;
    uint256 public lastMinAuctionScalar;

    constructor(address auction_) {
        auction = auction_;
    }

    function createAuction(AuctionConfig memory config) external returns (address) {
        lastController = config.controller;
        lastToken = config.token;
        lastMinAuctionScalar = config.minAuctionScalar;
        return auction;
    }
}

contract MockTreasury {
    bool public executed;
    bool public batchExecuted;
    uint256 public lastBatchLength;

    function execute(ITreasury.TreasuryCall memory) external returns (bool) {
        executed = true;
        return true;
    }

    function executeBatch(ITreasury.TreasuryCall[] memory calls) external returns (bool) {
        batchExecuted = true;
        lastBatchLength = calls.length;
        return true;
    }
}

contract MockTreasuryFactory is ITreasuryFactory {
    address public immutable treasury;

    constructor(address treasury_) {
        treasury = treasury_;
    }

    function createTreasury() external view returns (address) {
        return treasury;
    }
}

contract MockBorrowerReceiver {
    address public lastBorrowableAsset;
    uint256 public addBorrowableAssetCalls;

    function addBorrowableAsset(address asset) external {
        lastBorrowableAsset = asset;
        addBorrowableAssetCalls++;
    }
}

contract MockBorrowerFactory is IBorrowerFactory {
    address public immutable borrower;
    address public lastController;
    address public lastToken;

    constructor(address borrower_) {
        borrower = borrower_;
    }

    function createBorrower(BorrowerConfig memory config) external returns (address) {
        lastController = config.controller;
        lastToken = config.token;
        return borrower;
    }
}

contract ControllerTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant TEAM_COLLECTOR = address(0xBEEF);
    address internal constant CONFIG_OPERATOR = address(0xC0F1);
    address internal constant TOKEN_OPERATOR = address(0x7043);
    address internal constant TREASURER = address(0x7EA5);
    address internal constant AUCTIONEER = address(0xA117);
    address internal constant USER = address(0xB0B);
    address internal constant ASSET = address(0xA55E7);

    MockControllerToken internal token;
    MockAuction internal auction;
    MockAuctionFactory internal auctionFactory;
    MockTreasury internal treasury;
    MockTokenFactory internal tokenFactory;
    MockTreasuryFactory internal treasuryFactory;
    MockBorrowerReceiver internal borrowerReceiver;
    MockBorrowerFactory internal borrowerFactory;

    function setUp() public {
        token = new MockControllerToken();
        auction = new MockAuction();
        auctionFactory = new MockAuctionFactory(address(auction));
        treasury = new MockTreasury();
        tokenFactory = new MockTokenFactory(address(token));
        treasuryFactory = new MockTreasuryFactory(address(treasury));
        borrowerReceiver = new MockBorrowerReceiver();
        borrowerFactory = new MockBorrowerFactory(address(borrowerReceiver));
    }

    function test_constructorRevertsWhenBorrowerFactoryIsZero() public {
        IControllerFactory.ControllerConfig memory config = _config();
        config.borrowerFactory = address(0);

        vm.expectRevert(Controller.Controller__BorrowerFactoryMisconfigured.selector);
        new Controller(config);
    }

    function test_constructorGrantsAdminAndOperationalRolesToAdmin() public {
        Controller controller = new Controller(_config());

        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(controller.hasRole(controller.CONFIG_ROLE(), ADMIN));
        assertTrue(controller.hasRole(controller.TOKEN_ROLE(), ADMIN));
        assertTrue(controller.hasRole(controller.TREASURER_ROLE(), ADMIN));
        assertTrue(controller.hasRole(controller.AUCTIONEER_ROLE(), ADMIN));
        assertEq(controller.BORROWER_FACTORY(), address(borrowerFactory));
    }

    function test_initializeRevertsWhenCallerMissingConfigRole() public {
        Controller controller = new Controller(_config());
        bytes32 configRole = controller.CONFIG_ROLE();

        _expectUnauthorized(USER, configRole);
        vm.prank(USER);
        controller.initialize(_tokenConfig());
    }

    function test_initializeAuctionRevertsWhenCallerMissingConfigRole() public {
        Controller controller = new Controller(_config());
        bytes32 configRole = controller.CONFIG_ROLE();

        _expectUnauthorized(USER, configRole);
        vm.prank(USER);
        controller.initializeAuction(_auctionConfig());
    }

    function test_initializeBorrowerRevertsWhenCallerMissingConfigRole() public {
        Controller controller = new Controller(_config());
        bytes32 configRole = controller.CONFIG_ROLE();

        _expectUnauthorized(USER, configRole);
        vm.prank(USER);
        controller.initializeBorrower();
    }

    function test_addAssetRevertsWhenCallerMissingTokenRole() public {
        Controller controller = new Controller(_config());
        bytes32 tokenRole = controller.TOKEN_ROLE();

        _expectUnauthorized(USER, tokenRole);
        vm.prank(USER);
        controller.addAsset(ASSET);
    }

    function test_executeRevertsWhenCallerMissingTreasurerRole() public {
        Controller controller = new Controller(_config());
        bytes32 treasurerRole = controller.TREASURER_ROLE();

        _expectUnauthorized(USER, treasurerRole);
        vm.prank(USER);
        controller.execute(_treasuryCall());
    }

    function test_executeBatchRevertsWhenCallerMissingTreasurerRole() public {
        Controller controller = new Controller(_config());
        bytes32 treasurerRole = controller.TREASURER_ROLE();
        ITreasury.TreasuryCall[] memory calls = new ITreasury.TreasuryCall[](1);
        calls[0] = _treasuryCall();

        _expectUnauthorized(USER, treasurerRole);
        vm.prank(USER);
        controller.executeBatch(calls);
    }

    function test_startNextAuctionRevertsWhenCallerMissingAuctioneerRole() public {
        Controller controller = new Controller(_config());
        bytes32 auctioneerRole = controller.AUCTIONEER_ROLE();

        _expectUnauthorized(USER, auctioneerRole);
        vm.prank(USER);
        controller.startNextAuction();
    }

    function test_initializeBorrowerUsesControllerOwnedConfig() public {
        Controller controller = new Controller(_config());

        ITokenFactory.TokenConfig memory tokenConfig = _tokenConfig();

        vm.prank(ADMIN);
        controller.initialize(tokenConfig);

        vm.prank(ADMIN);
        controller.initializeBorrower();

        assertEq(controller.borrower(), address(borrowerReceiver));
        assertEq(borrowerFactory.lastController(), address(controller));
        assertEq(borrowerFactory.lastToken(), address(token));
        assertEq(token.borrower(), address(borrowerReceiver));
    }

    function test_defaultAdminCanGrantConfigRoleAndOperatorCanInitializeAuction() public {
        Controller controller = new Controller(_config());
        bytes32 configRole = controller.CONFIG_ROLE();

        vm.prank(ADMIN);
        controller.grantRole(configRole, CONFIG_OPERATOR);

        vm.prank(CONFIG_OPERATOR);
        controller.initialize(_tokenConfig());

        vm.prank(CONFIG_OPERATOR);
        controller.initializeAuction(_auctionConfig());

        assertEq(controller.auction(), address(auction));
        assertEq(auctionFactory.lastController(), address(controller));
    }

    function test_defaultAdminCanGrantTokenRoleAndOperatorCanAddAsset() public {
        Controller controller = new Controller(_config());
        bytes32 tokenRole = controller.TOKEN_ROLE();

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig());
        controller.initializeBorrower();
        controller.grantRole(tokenRole, TOKEN_OPERATOR);
        vm.stopPrank();

        vm.prank(TOKEN_OPERATOR);
        controller.addAsset(ASSET);

        address[] memory assets = token.assets();
        assertEq(assets.length, 1);
        assertEq(assets[0], ASSET);
        assertEq(borrowerReceiver.lastBorrowableAsset(), ASSET);
        assertEq(borrowerReceiver.addBorrowableAssetCalls(), 1);
    }

    function test_defaultAdminCanGrantTreasurerRoleAndOperatorCanExecute() public {
        Controller controller = new Controller(_config());
        bytes32 treasurerRole = controller.TREASURER_ROLE();

        vm.prank(ADMIN);
        controller.initialize(_tokenConfig());

        vm.prank(ADMIN);
        controller.grantRole(treasurerRole, TREASURER);

        vm.prank(TREASURER);
        controller.execute(_treasuryCall());

        assertTrue(treasury.executed());
    }

    function test_defaultAdminCanGrantAuctioneerRoleAndOperatorCanStartAuction() public {
        Controller controller = new Controller(_config());
        bytes32 auctioneerRole = controller.AUCTIONEER_ROLE();

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig());
        controller.initializeAuction(_auctionConfig());
        controller.grantRole(auctioneerRole, AUCTIONEER);
        vm.stopPrank();

        vm.prank(AUCTIONEER);
        controller.startNextAuction();

        assertTrue(auction.started());
    }

    function _config() internal view returns (IControllerFactory.ControllerConfig memory config) {
        config = IControllerFactory.ControllerConfig({
            admin: ADMIN,
            teamCollector: TEAM_COLLECTOR,
            backingFee: 8000,
            treasuryFee: 900,
            teamFee: 1000,
            maxAssets: 5,
            auctionFactory: address(auctionFactory),
            tokenFactory: address(tokenFactory),
            treasuryFactory: address(treasuryFactory),
            borrowerFactory: address(borrowerFactory)
        });
    }

    function _tokenConfig() internal pure returns (ITokenFactory.TokenConfig memory config) {
        config = ITokenFactory.TokenConfig({
            name: "Enten", symbol: "ENT", controller: address(0xDEAD), maxSupply: type(uint256).max
        });
    }

    function _auctionConfig() internal view returns (IAuctionFactory.AuctionConfig memory config) {
        config = IAuctionFactory.AuctionConfig({
            controller: address(0xDEAD),
            token: address(token),
            lotSize: 1e18,
            epochPeriod: 1 days,
            auctionScalar: 2e18,
            minAuctionScalar: 1e18
        });
    }

    function _treasuryCall() internal pure returns (ITreasury.TreasuryCall memory call) {
        call = ITreasury.TreasuryCall({action: ITreasury.Action.DeployFunds, data: bytes("")});
    }

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }
}
