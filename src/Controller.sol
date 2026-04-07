///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "openzeppelin/access/AccessControl.sol";
import {IAuction} from "./interfaces/IAuction.sol";
import {IBorrower} from "./interfaces/IBorrower.sol";
import {IControllerCallback} from "./interfaces/IControllerCallback.sol";
import {IToken} from "./interfaces/IToken.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {ITreasuryFactory} from "./interfaces/factories/ITreasuryFactory.sol";
import {IAuctionFactory} from "./interfaces/factories/IAuctionFactory.sol";
import {ITokenFactory} from "./interfaces/factories/ITokenFactory.sol";
import {IControllerFactory} from "./interfaces/factories/IControllerFactory.sol";
import {IBorrowerFactory} from "./interfaces/factories/IBorrowerFactory.sol";

contract Controller is AccessControl, IControllerCallback {
    uint256 internal constant FEE_DIVISOR = 10_000;
    uint256 public constant PROTOCOL_FEE = 100;
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant TOKEN_ROLE = keccak256("TOKEN_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant AUCTIONEER_ROLE = keccak256("AUCTIONEER_ROLE");
    address public constant PROTOCOL_COLLECTOR = address(0);
    address public immutable TEAM_COLLECTOR;
    uint256 public immutable BACKING_FEE;
    uint256 public immutable TREASURY_FEE;
    uint256 public immutable TEAM_FEE;
    uint256 public immutable MAX_ASSETS;

    address public immutable AUCTION_FACTORY;
    address public immutable TOKEN_FACTORY;
    address public immutable TREASURY_FACTORY;
    address public immutable BORROWER_FACTORY;

    address public token;
    address public treasury;
    address public auction;
    address public borrower;

    error Controller__NotAuction();
    error Controller__MaxAssets();
    error Controller__AuctionExceedsMaxSupply();
    error Controller__AuctionInitialized();
    error Controller__AlreadyInitialized();
    error Controller__NotInitialized();
    error Controller__AdminMisconfigured();
    error Controller__ProtocolCollectorMisconfigured();
    error Controller__TeamCollectorMisconfigured();
    error Controller__AuctionFactoryMisconfigured();
    error Controller__TokenFactoryMisconfigured();
    error Controller__TreasuryFactoryMisconfigured();
    error Controller__BorrowerFactoryMisconfigured();
    error Controller__MaxAssetsZero();
    error Controller__FeeOutOfRange();
    error Controller__FeeSumInvalid();
    error Controller__BorrowerConfiguration();

    constructor(IControllerFactory.ControllerConfig memory config) {
        if (config.admin == address(0)) revert Controller__AdminMisconfigured();
        if (config.maxAssets == 0) revert Controller__MaxAssetsZero();

        if (config.backingFee > FEE_DIVISOR || config.treasuryFee > FEE_DIVISOR || config.teamFee > FEE_DIVISOR) {
            revert Controller__FeeOutOfRange();
        }

        uint256 feeSum = config.backingFee + PROTOCOL_FEE + config.treasuryFee + config.teamFee;
        if (feeSum != FEE_DIVISOR) revert Controller__FeeSumInvalid();

        if (config.teamFee > 0 && config.teamCollector == address(0)) {
            revert Controller__TeamCollectorMisconfigured();
        }

        if (config.auctionFactory == address(0)) revert Controller__AuctionFactoryMisconfigured();
        if (config.tokenFactory == address(0)) revert Controller__TokenFactoryMisconfigured();
        if (config.treasuryFactory == address(0)) revert Controller__TreasuryFactoryMisconfigured();
        if (config.borrowerFactory == address(0)) revert Controller__BorrowerFactoryMisconfigured();

        _grantRole(DEFAULT_ADMIN_ROLE, config.admin);
        _grantRole(CONFIG_ROLE, config.admin);
        _grantRole(TOKEN_ROLE, config.admin);
        _grantRole(TREASURER_ROLE, config.admin);
        _grantRole(AUCTIONEER_ROLE, config.admin);

        TEAM_COLLECTOR = config.teamCollector;
        BACKING_FEE = config.backingFee;
        TREASURY_FEE = config.treasuryFee;
        TEAM_FEE = config.teamFee;
        MAX_ASSETS = config.maxAssets;

        AUCTION_FACTORY = config.auctionFactory;
        TOKEN_FACTORY = config.tokenFactory;
        TREASURY_FACTORY = config.treasuryFactory;
        BORROWER_FACTORY = config.borrowerFactory;
    }

    function initialize(ITokenFactory.TokenConfig memory config) external onlyRole(CONFIG_ROLE) {
        if (token != address(0)) revert Controller__AlreadyInitialized();
        config.controller = address(this);
        token = ITokenFactory(TOKEN_FACTORY).createToken(config);
        treasury = ITreasuryFactory(TREASURY_FACTORY).createTreasury();
    }

    function initializeAuction(IAuctionFactory.AuctionConfig memory config) external onlyRole(CONFIG_ROLE) {
        if (auction != address(0)) revert Controller__AuctionInitialized();
        config.minAuctionScalar = _calculateMinScalar();
        config.controller = address(this);
        auction = IAuctionFactory(AUCTION_FACTORY).createAuction(config);
    }

    function initializeBorrower() external onlyRole(CONFIG_ROLE) {
        if (token == address(0) || borrower != address(0)) revert Controller__BorrowerConfiguration();
        IBorrowerFactory.BorrowerConfig memory config =
            IBorrowerFactory.BorrowerConfig({controller: address(this), token: token});
        address borrowerAddr = IBorrowerFactory(BORROWER_FACTORY).createBorrower(config);
        borrower = borrowerAddr;
        IToken(token).addBorrower(borrowerAddr);
    }

    /* AUCTION FUNCTIONS*/
    function buy(uint256 amount, uint256 deadline, uint256 epochId) external {
        IAuction(auction).bid(amount, deadline, epochId, msg.sender);
    }

    function finalizeBuy(IControllerCallback.CallbackValue[] memory values, address account) external returns (bool) {
        if (msg.sender != auction) revert Controller__NotAuction();
        for (uint256 i = 0; i < values.length; i++) {
            bool success = IToken(values[i].asset).transferFrom(account, address(this), values[i].value);
            require(success);
        }
        return true;
    }

    /* Start the next auction and distribute previous auction profits*/
    function startNextAuction() external onlyRole(AUCTIONEER_ROLE) {
        if (token == address(0)) revert Controller__NotInitialized();
        address[] memory assets = IToken(token).assets();
        for (uint256 i = 0; i < assets.length; i++) {
            _split(assets[i], IToken(assets[i]).balanceOf(address(this)));
        }
        if (IAuction(auction).LOT_SIZE() + IToken(token).totalSupply() > IToken(token).MAX_SUPPLY()) {
            revert Controller__AuctionExceedsMaxSupply();
        }
        IAuction(auction).start();
    }

    /* TOKEN FUNCTIONS */

    function redeem(uint256 amount) external {
        IToken(token).redeem(msg.sender, amount);
    }

    function burn(uint256 amount) external {
        IToken(token).burn(msg.sender, amount);
    }

    function addAsset(address asset) external onlyRole(TOKEN_ROLE) {
        if (IToken(token).assets().length == MAX_ASSETS) revert Controller__MaxAssets();
        if (token == address(0) || borrower == address(0)) revert Controller__NotInitialized();
        IToken(token).addAsset(asset);
        IBorrower(borrower).addBorrowableAsset(asset);
    }

    /* TREASURY FUNCTIONS */

    function execute(ITreasury.TreasuryCall memory call) external onlyRole(TREASURER_ROLE) {
        bool success = ITreasury(treasury).execute(call);
        require(success);
    }

    function executeBatch(ITreasury.TreasuryCall[] memory calls) external onlyRole(TREASURER_ROLE) {
        bool success = ITreasury(treasury).executeBatch(calls);
        require(success);
    }

    /* ADMIN FUNCTIONS */

    /* INTERNAL FUNCTIONS */

    function _split(address asset, uint256 amount) internal {
        uint256 backingAmount = amount * BACKING_FEE / FEE_DIVISOR;
        uint256 protocolAmount = amount * PROTOCOL_FEE / FEE_DIVISOR;
        uint256 treasuryAmount = amount * TREASURY_FEE / FEE_DIVISOR;
        uint256 teamAmount = amount * TEAM_FEE / FEE_DIVISOR;

        _transfer(asset, token, backingAmount);
        _transfer(asset, PROTOCOL_COLLECTOR, protocolAmount);
        _transfer(asset, treasury, treasuryAmount);
        _transfer(asset, TEAM_COLLECTOR, teamAmount);
    }

    function _transfer(address asset, address to, uint256 amount) internal {
        bool success = IToken(asset).transfer(to, amount);
        require(success);
    }

    function _calculateMinScalar() internal view returns (uint256) {
        return (1e18 * FEE_DIVISOR + BACKING_FEE - 1) / BACKING_FEE;
    }
}
