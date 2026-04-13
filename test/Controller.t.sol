///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin/access/IAccessControl.sol";
import {ERC20Mock} from "openzeppelin/mocks/token/ERC20Mock.sol";
import {Controller} from "../src/Controller.sol";
import {IControllerCallback} from "../src/interfaces/IControllerCallback.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {IAuctionFactory} from "../src/interfaces/factories/IAuctionFactory.sol";
import {IControllerFactory} from "../src/interfaces/factories/IControllerFactory.sol";
import {ITokenFactory} from "../src/interfaces/factories/ITokenFactory.sol";
import {ITreasuryFactory} from "../src/interfaces/factories/ITreasuryFactory.sol";
import {IBorrowerFactory} from "../src/interfaces/factories/IBorrowerFactory.sol";

contract MockControllerToken {
    address public borrower;
    uint256 public totalSupply;
    uint256 public maxSupply = type(uint256).max;
    address public lastMintAccount;
    uint256 public lastMintAmount;
    address public lastRedeemAccount;
    uint256 public lastRedeemAmount;
    address public lastBurnAccount;
    uint256 public lastBurnAmount;

    mapping(address => bool) private _knownAssets;
    address[] private _assets;

    function setSupplyAndMax(uint256 supply, uint256 maxSupply_) external {
        totalSupply = supply;
        maxSupply = maxSupply_;
    }

    function MAX_SUPPLY() external view returns (uint256) {
        return maxSupply;
    }

    function mint(address account, uint256 amount) external {
        lastMintAccount = account;
        lastMintAmount = amount;
        totalSupply += amount;
    }

    function redeem(address account, uint256 amount) external {
        lastRedeemAccount = account;
        lastRedeemAmount = amount;
    }

    function burn(address account, uint256 amount) external {
        lastBurnAccount = account;
        lastBurnAmount = amount;
    }

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
    address private immutable TOKEN;
    TokenConfig public lastConfig;

    constructor(address token_) {
        TOKEN = token_;
    }

    function createToken(TokenConfig memory config) external returns (address) {
        lastConfig = config;
        return TOKEN;
    }
}

contract MockAuction {
    uint256 public constant LOT_SIZE = 1e18;
    bool public started;
    bool public live;
    uint256 public bidReturnAmount;
    uint256 public lastBidAmount;
    uint256 public lastBidDeadline;
    uint256 public lastBidEpochId;
    address public lastBidBuyer;

    function setBidReturnAmount(uint256 amount) external {
        bidReturnAmount = amount;
    }

    function setLive(bool live_) external {
        live = live_;
    }

    function start() external {
        started = true;
    }

    function bid(uint256 amount, uint256 deadline, uint256 epochId, address buyer) external returns (uint256) {
        lastBidAmount = amount;
        lastBidDeadline = deadline;
        lastBidEpochId = epochId;
        lastBidBuyer = buyer;
        return bidReturnAmount;
    }

    function isLive() external view returns (bool) {
        return live;
    }
}

contract MockAuctionFactory is IAuctionFactory {
    address private immutable AUCTION;
    address public lastController;
    address public lastToken;
    uint256 public lastMinAuctionScalar;

    constructor(address auction_) {
        AUCTION = auction_;
    }

    function createAuction(AuctionConfig memory config) external returns (address) {
        lastController = config.controller;
        lastToken = config.token;
        lastMinAuctionScalar = config.minAuctionScalar;
        return AUCTION;
    }
}

contract MockTreasury {
    bool public executed;
    bool public batchExecuted;
    uint256 public lastBatchLength;
    bool public executionResult = true;

    function setExecutionResult(bool executionResult_) external {
        executionResult = executionResult_;
    }

    function execute(ITreasury.TreasuryCall memory) external returns (bool) {
        executed = true;
        return executionResult;
    }

    function executeBatch(ITreasury.TreasuryCall[] memory calls) external returns (bool) {
        batchExecuted = true;
        lastBatchLength = calls.length;
        return executionResult;
    }
}

contract MockTreasuryFactory is ITreasuryFactory {
    address private immutable TREASURY;

    constructor(address treasury_) {
        TREASURY = treasury_;
    }

    function createTreasury(address, uint256) external view returns (address) {
        return TREASURY;
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
    address private immutable BORROWER;
    address public lastController;
    address public lastToken;

    constructor(address borrower_) {
        BORROWER = borrower_;
    }

    function createBorrower(BorrowerConfig memory config) external returns (address) {
        lastController = config.controller;
        lastToken = config.token;
        return BORROWER;
    }
}

contract PermissiveTransferAsset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance < amount || balanceOf[from] < amount) return false;
        if (currentAllowance != type(uint256).max) {
            allowance[from][msg.sender] = currentAllowance - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
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
    uint256 internal constant MAX_STRATEGIES = 5;

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

    function test_constructorRevertsWhenAdminIsZero() public {
        IControllerFactory.ControllerConfig memory config = _config();
        config.admin = address(0);

        vm.expectRevert(Controller.Controller__AdminMisconfigured.selector);
        new Controller(config);
    }

    function test_constructorRevertsWhenMaxAssetsIsZero() public {
        IControllerFactory.ControllerConfig memory config = _config();
        config.maxAssets = 0;

        vm.expectRevert(Controller.Controller__MaxAssetsZero.selector);
        new Controller(config);
    }

    function test_constructorRevertsWhenFeeIsOutOfRange() public {
        IControllerFactory.ControllerConfig memory config = _config();
        config.backingFee = 10_001;

        vm.expectRevert(Controller.Controller__FeeOutOfRange.selector);
        new Controller(config);
    }

    function test_constructorRevertsWhenFeeSumIsInvalid() public {
        IControllerFactory.ControllerConfig memory config = _config();
        config.backingFee = 7_999;

        vm.expectRevert(Controller.Controller__FeeSumInvalid.selector);
        new Controller(config);
    }

    function test_constructorRevertsWhenTeamCollectorIsZeroAndTeamFeeIsNonZero() public {
        IControllerFactory.ControllerConfig memory config = _config();
        config.teamCollector = address(0);

        vm.expectRevert(Controller.Controller__TeamCollectorMisconfigured.selector);
        new Controller(config);
    }

    function test_constructorRevertsWhenAuctionFactoryIsZero() public {
        IControllerFactory.ControllerConfig memory config = _config();
        config.auctionFactory = address(0);

        vm.expectRevert(Controller.Controller__AuctionFactoryMisconfigured.selector);
        new Controller(config);
    }

    function test_constructorRevertsWhenTokenFactoryIsZero() public {
        IControllerFactory.ControllerConfig memory config = _config();
        config.tokenFactory = address(0);

        vm.expectRevert(Controller.Controller__TokenFactoryMisconfigured.selector);
        new Controller(config);
    }

    function test_constructorRevertsWhenTreasuryFactoryIsZero() public {
        IControllerFactory.ControllerConfig memory config = _config();
        config.treasuryFactory = address(0);

        vm.expectRevert(Controller.Controller__TreasuryFactoryMisconfigured.selector);
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
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
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
        controller.initialize(tokenConfig, MAX_STRATEGIES);

        vm.prank(ADMIN);
        controller.initializeBorrower();

        assertEq(controller.borrower(), address(borrowerReceiver));
        assertEq(borrowerFactory.lastController(), address(controller));
        assertEq(borrowerFactory.lastToken(), address(token));
        assertEq(token.borrower(), address(borrowerReceiver));
    }

    function test_initializeRevertsWhenAlreadyInitialized() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        vm.expectRevert(Controller.Controller__AlreadyInitialized.selector);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        vm.stopPrank();
    }

    function test_initializeAuctionRevertsWhenAlreadyInitialized() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        vm.expectRevert(Controller.Controller__AuctionInitialized.selector);
        controller.initializeAuction(_auctionConfig());
        vm.stopPrank();
    }

    function test_initializeBorrowerRevertsBeforeTokenInitialized() public {
        Controller controller = new Controller(_config());

        vm.prank(ADMIN);
        vm.expectRevert(Controller.Controller__BorrowerConfiguration.selector);
        controller.initializeBorrower();
    }

    function test_initializeBorrowerRevertsWhenAlreadyInitialized() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeBorrower();
        vm.expectRevert(Controller.Controller__BorrowerConfiguration.selector);
        controller.initializeBorrower();
        vm.stopPrank();
    }

    function test_defaultAdminCanGrantConfigRoleAndOperatorCanInitializeAuction() public {
        Controller controller = new Controller(_config());
        bytes32 configRole = controller.CONFIG_ROLE();

        vm.prank(ADMIN);
        controller.grantRole(configRole, CONFIG_OPERATOR);

        vm.prank(CONFIG_OPERATOR);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);

        vm.prank(CONFIG_OPERATOR);
        controller.initializeAuction(_auctionConfig());

        assertEq(controller.auction(), address(auction));
        assertEq(auctionFactory.lastController(), address(controller));
    }

    function test_defaultAdminCanGrantTokenRoleAndOperatorCanAddAsset() public {
        Controller controller = new Controller(_config());
        bytes32 tokenRole = controller.TOKEN_ROLE();

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
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

    function test_addAssetRevertsWhenAuctionIsLive() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        controller.initializeBorrower();
        auction.setLive(true);
        vm.expectRevert(Controller.Controller__AuctionOngoing.selector);
        controller.addAsset(ASSET);
        vm.stopPrank();
    }

    function test_addAssetRevertsWhenMaxAssetsReached() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        controller.initializeBorrower();
        for (uint160 i = 1; i <= 5; i++) {
            controller.addAsset(address(i));
        }
        vm.expectRevert(Controller.Controller__MaxAssets.selector);
        controller.addAsset(address(6));
        vm.stopPrank();
    }

    function test_addAssetRevertsWhenAuctionIsNotInitialized() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeBorrower();
        vm.expectRevert(Controller.Controller__NotInitialized.selector);
        controller.addAsset(ASSET);
        vm.stopPrank();
    }

    function test_buyRevertsWhenMintAmountIsBelowMinimum() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        vm.stopPrank();

        auction.setBidReturnAmount(0.5e18);

        vm.prank(USER);
        vm.expectRevert(Controller.Controller__MinMintAmount.selector);
        controller.buy(1e18, block.timestamp, 1, 0.5e18 + 1);

        assertEq(token.lastMintAccount(), address(0));
        assertEq(token.lastMintAmount(), 0);
    }

    function test_buyMintsWhenMintAmountMeetsMinimum() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        vm.stopPrank();

        auction.setBidReturnAmount(0.5e18);

        vm.prank(USER);
        controller.buy(1e18, block.timestamp, 1, 0.5e18);

        assertEq(auction.lastBidAmount(), 1e18);
        assertEq(auction.lastBidDeadline(), block.timestamp);
        assertEq(auction.lastBidEpochId(), 1);
        assertEq(auction.lastBidBuyer(), USER);
        assertEq(token.lastMintAccount(), USER);
        assertEq(token.lastMintAmount(), 0.5e18);
    }

    function test_finalizeBuyRevertsWhenCallerIsNotAuction() public {
        Controller controller = new Controller(_config());
        IControllerCallback.CallbackValue[] memory values = new IControllerCallback.CallbackValue[](0);

        vm.expectRevert(Controller.Controller__NotAuction.selector);
        controller.finalizeBuy(values, USER);
    }

    function test_finalizeBuySplitsBuyerPaymentAcrossCollectors() public {
        Controller controller = new Controller(_config());
        PermissiveTransferAsset asset = new PermissiveTransferAsset();
        uint256 amount = 10_000;

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        vm.stopPrank();

        asset.mint(USER, amount);

        vm.prank(USER);
        asset.approve(address(controller), amount);

        IControllerCallback.CallbackValue[] memory values = new IControllerCallback.CallbackValue[](1);
        values[0] = IControllerCallback.CallbackValue({asset: address(asset), value: amount});

        vm.prank(address(auction));
        assertTrue(controller.finalizeBuy(values, USER));

        assertEq(asset.balanceOf(address(token)), 8_000);
        assertEq(asset.balanceOf(controller.PROTOCOL_COLLECTOR()), 100);
        assertEq(asset.balanceOf(address(treasury)), 900);
        assertEq(asset.balanceOf(TEAM_COLLECTOR), 1_000);
        assertEq(asset.balanceOf(USER), 0);
    }

    function test_finalizeBuyRevertsWhenAssetTransferFails() public {
        Controller controller = new Controller(_config());
        PermissiveTransferAsset asset = new PermissiveTransferAsset();

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        vm.stopPrank();

        IControllerCallback.CallbackValue[] memory values = new IControllerCallback.CallbackValue[](1);
        values[0] = IControllerCallback.CallbackValue({asset: address(asset), value: 1});

        vm.prank(address(auction));
        vm.expectRevert();
        controller.finalizeBuy(values, USER);
    }

    function test_finalizeBuyRevertsWithStandardErc20BecauseProtocolCollectorIsZero() public {
        Controller controller = new Controller(_config());
        ERC20Mock asset = new ERC20Mock();
        uint256 amount = 10_000;

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        vm.stopPrank();

        asset.mint(USER, amount);

        vm.prank(USER);
        asset.approve(address(controller), amount);

        IControllerCallback.CallbackValue[] memory values = new IControllerCallback.CallbackValue[](1);
        values[0] = IControllerCallback.CallbackValue({asset: address(asset), value: amount});

        vm.prank(address(auction));
        vm.expectRevert();
        controller.finalizeBuy(values, USER);
    }

    function test_startNextAuctionRevertsWhenAuctionWouldExceedMaxSupply() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        token.setSupplyAndMax(2e18, 2e18);
        vm.expectRevert(Controller.Controller__AuctionExceedsMaxSupply.selector);
        controller.startNextAuction();
        vm.stopPrank();
    }

    function test_startNextAuctionRevertsWhenControllerIsNotInitialized() public {
        Controller controller = new Controller(_config());

        vm.prank(ADMIN);
        vm.expectRevert(Controller.Controller__NotInitialized.selector);
        controller.startNextAuction();
    }

    function test_startNextAuctionRevertsWhenAuctionIsLive() public {
        Controller controller = new Controller(_config());

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.initializeAuction(_auctionConfig());
        auction.setLive(true);
        vm.expectRevert(Controller.Controller__AuctionOngoing.selector);
        controller.startNextAuction();
        vm.stopPrank();
    }

    function test_redeemForwardsCallerAndAmountToToken() public {
        Controller controller = new Controller(_config());

        vm.prank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);

        vm.prank(USER);
        controller.redeem(0.25e18);

        assertEq(token.lastRedeemAccount(), USER);
        assertEq(token.lastRedeemAmount(), 0.25e18);
    }

    function test_burnForwardsCallerAndAmountToToken() public {
        Controller controller = new Controller(_config());

        vm.prank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);

        vm.prank(USER);
        controller.burn(0.25e18);

        assertEq(token.lastBurnAccount(), USER);
        assertEq(token.lastBurnAmount(), 0.25e18);
    }

    function test_executeRevertsWhenTreasuryReturnsFalse() public {
        Controller controller = new Controller(_config());
        bytes32 treasurerRole = controller.TREASURER_ROLE();

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.grantRole(treasurerRole, TREASURER);
        treasury.setExecutionResult(false);
        vm.stopPrank();

        vm.prank(TREASURER);
        vm.expectRevert();
        controller.execute(_treasuryCall());
    }

    function test_executeBatchRevertsWhenTreasuryReturnsFalse() public {
        Controller controller = new Controller(_config());
        bytes32 treasurerRole = controller.TREASURER_ROLE();
        ITreasury.TreasuryCall[] memory calls = new ITreasury.TreasuryCall[](1);
        calls[0] = _treasuryCall();

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
        controller.grantRole(treasurerRole, TREASURER);
        treasury.setExecutionResult(false);
        vm.stopPrank();

        vm.prank(TREASURER);
        vm.expectRevert();
        controller.executeBatch(calls);
    }

    function test_defaultAdminCanGrantTreasurerRoleAndOperatorCanExecute() public {
        Controller controller = new Controller(_config());
        bytes32 treasurerRole = controller.TREASURER_ROLE();

        vm.prank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);

        vm.prank(ADMIN);
        controller.grantRole(treasurerRole, TREASURER);

        vm.prank(TREASURER);
        controller.execute(_treasuryCall());

        assertTrue(treasury.executed());
    }

    function test_defaultAdminCanGrantTreasurerRoleAndOperatorCanExecuteBatch() public {
        Controller controller = new Controller(_config());
        bytes32 treasurerRole = controller.TREASURER_ROLE();
        ITreasury.TreasuryCall[] memory calls = new ITreasury.TreasuryCall[](2);
        calls[0] = _treasuryCall();
        calls[1] = _treasuryCall();

        vm.prank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);

        vm.prank(ADMIN);
        controller.grantRole(treasurerRole, TREASURER);

        vm.prank(TREASURER);
        controller.executeBatch(calls);

        assertTrue(treasury.batchExecuted());
        assertEq(treasury.lastBatchLength(), 2);
    }

    function test_defaultAdminCanGrantAuctioneerRoleAndOperatorCanStartAuction() public {
        Controller controller = new Controller(_config());
        bytes32 auctioneerRole = controller.AUCTIONEER_ROLE();

        vm.startPrank(ADMIN);
        controller.initialize(_tokenConfig(), MAX_STRATEGIES);
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
            name: "Enten",
            symbol: "ENT",
            controller: address(0xDEAD),
            maxSupply: type(uint256).max,
            preMintReceiver: ADMIN,
            preMintAmount: 1e18
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
