///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "openzeppelin/mocks/token/ERC20Mock.sol";

import {Auction} from "../src/Auction.sol";
import {Borrower} from "../src/Borrower.sol";
import {Controller} from "../src/Controller.sol";
import {Token} from "../src/Token.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {IAuctionFactory} from "../src/interfaces/factories/IAuctionFactory.sol";
import {IBorrowerFactory} from "../src/interfaces/factories/IBorrowerFactory.sol";
import {IControllerFactory} from "../src/interfaces/factories/IControllerFactory.sol";
import {ITokenFactory} from "../src/interfaces/factories/ITokenFactory.sol";
import {ITreasuryFactory} from "../src/interfaces/factories/ITreasuryFactory.sol";

contract DeployingTokenFactory is ITokenFactory {
    function createToken(TokenConfig memory config) external returns (address) {
        return address(new Token(config));
    }
}

contract DeployingAuctionFactory is IAuctionFactory {
    function createAuction(AuctionConfig memory config) external returns (address) {
        return address(new Auction(config));
    }
}

contract DeployingBorrowerFactory is IBorrowerFactory {
    function createBorrower(BorrowerConfig memory config) external returns (address) {
        return address(new Borrower(config.controller, config.token));
    }
}

contract DummyTreasury is ITreasury {
    function execute(TreasuryCall memory) external pure returns (bool) {
        return true;
    }

    function executeBatch(TreasuryCall[] memory) external pure returns (bool) {
        return true;
    }
}

contract DummyTreasuryFactory is ITreasuryFactory {
    function createTreasury() external returns (address) {
        return address(new DummyTreasury());
    }
}

contract SecurityReviewTest is Test {
    uint256 internal constant PREMINT = 100e18;
    uint256 internal constant MAX_SUPPLY = 1_000e18;
    uint256 internal constant LOT_SIZE = 50e18;
    uint256 internal constant EPOCH_PERIOD = 1 days;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant BUYER = address(0xB0B);
    address internal constant TEAM_COLLECTOR = address(0xBEEF);

    DeployingTokenFactory internal tokenFactory;
    DeployingAuctionFactory internal auctionFactory;
    DeployingBorrowerFactory internal borrowerFactory;
    DummyTreasuryFactory internal treasuryFactory;

    function setUp() public {
        tokenFactory = new DeployingTokenFactory();
        auctionFactory = new DeployingAuctionFactory();
        borrowerFactory = new DeployingBorrowerFactory();
        treasuryFactory = new DummyTreasuryFactory();
    }

    function testFuzz_buyRevertsWithoutMintingWhenAuctionHasNoPrices(uint96 rawAmount) public {
        (Controller controller, Token token, Auction auction) = _deployController();
        uint256 requestedAmount = bound(uint256(rawAmount), 1, LOT_SIZE * 2);
        uint256 epochId;

        vm.prank(ADMIN);
        controller.startNextAuction();
        epochId = auction.currentEpoch();

        uint256 buyerBalanceBefore = token.balanceOf(BUYER);
        uint256 totalSupplyBefore = token.totalSupply();

        vm.expectRevert(Auction.Auction__ZeroPricesReturned.selector);
        vm.prank(BUYER);
        controller.buy(requestedAmount, block.timestamp, epochId);

        assertEq(token.balanceOf(BUYER), buyerBalanceBefore);
        assertEq(token.totalSupply(), totalSupplyBefore);
    }

    function test_startNextAuctionSucceedsAfterAssetRegistrationWhenNoPendingProceeds() public {
        (Controller controller, Token token, Auction auction) = _deployController();
        ERC20Mock asset = new ERC20Mock();

        vm.prank(ADMIN);
        controller.initializeBorrower();

        asset.mint(address(this), PREMINT);
        asset.transfer(address(token), PREMINT);

        vm.prank(ADMIN);
        controller.addAsset(address(asset));

        vm.prank(ADMIN);
        controller.startNextAuction();

        assertEq(auction.currentEpoch(), 1);
        assertEq(auction.remainingLot(), LOT_SIZE);
    }

    function testFuzz_tokenConstructorRevertsWhenPreMintExceedsMaxSupply(uint128 maxSupply, uint128 extra) public {
        maxSupply = uint128(bound(maxSupply, 1, type(uint120).max));
        extra = uint128(bound(extra, 1, type(uint120).max));

        vm.expectRevert(Token.Token__PreMintMisconfigured.selector);
        new Token(
            ITokenFactory.TokenConfig({
                name: "Enten",
                symbol: "ENT",
                controller: address(this),
                maxSupply: uint256(maxSupply),
                preMintReceiver: ADMIN,
                preMintAmount: uint256(maxSupply) + uint256(extra)
            })
        );
    }

    function _deployController() internal returns (Controller controller, Token token, Auction auction) {
        controller = new Controller(_controllerConfig());

        vm.prank(ADMIN);
        controller.initialize(_tokenConfig());

        token = Token(controller.token());

        vm.prank(ADMIN);
        controller.initializeAuction(_auctionConfig(address(token)));

        auction = Auction(controller.auction());
    }

    function _controllerConfig() internal view returns (IControllerFactory.ControllerConfig memory config) {
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
            controller: address(0),
            maxSupply: MAX_SUPPLY,
            preMintReceiver: ADMIN,
            preMintAmount: PREMINT
        });
    }

    function _auctionConfig(address token) internal pure returns (IAuctionFactory.AuctionConfig memory config) {
        config = IAuctionFactory.AuctionConfig({
            controller: address(0),
            token: token,
            lotSize: LOT_SIZE,
            epochPeriod: EPOCH_PERIOD,
            auctionScalar: 2e18,
            minAuctionScalar: 1e18
        });
    }
}
