///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

import {Auction} from "../src/Auction.sol";
import {IControllerCallback} from "../src/interfaces/IControllerCallback.sol";
import {IToken} from "../src/interfaces/IToken.sol";
import {IAuctionFactory} from "../src/interfaces/factories/IAuctionFactory.sol";

contract AuctionTokenMock is ERC20, IToken {
    uint256 public constant MAX_SUPPLY = type(uint256).max;

    IToken.AssetValue[] private _prices;

    constructor() ERC20("Enten", "ENT") {}

    function setPrices(address[] memory assets_, uint256[] memory values_) external {
        delete _prices;
        for (uint256 i = 0; i < assets_.length; i++) {
            _prices.push(IToken.AssetValue({asset: assets_[i], value: values_[i]}));
        }
    }

    function prices() external view returns (IToken.AssetValue[] memory values) {
        values = new IToken.AssetValue[](_prices.length);
        for (uint256 i = 0; i < _prices.length; i++) {
            values[i] = _prices[i];
        }
    }

    function price(address asset) external view returns (uint256) {
        for (uint256 i = 0; i < _prices.length; i++) {
            if (_prices[i].asset == asset) return _prices[i].value;
        }
        return 0;
    }

    function assets() external view returns (address[] memory assets_) {
        assets_ = new address[](_prices.length);
        for (uint256 i = 0; i < _prices.length; i++) {
            assets_[i] = _prices[i].asset;
        }
    }

    function addAsset(address) external {}

    function addBorrower(address) external {}

    function mint(address, uint256) external {}

    function burn(address, uint256) external {}

    function redeem(address, uint256) external {}

    function fulfillBorrow(address, address, uint256) external {}
}

contract AuctionTest is Test, IControllerCallback {
    uint256 internal constant LOT_SIZE = 100e18;
    uint256 internal constant EPOCH_PERIOD = 100;
    uint256 internal constant AUCTION_SCALAR = 2e18;
    uint256 internal constant MIN_AUCTION_SCALAR = 1e18;

    address internal constant ASSET = address(0xA11CE);
    address internal constant SECOND_ASSET = address(0xB0B);
    address internal constant BUYER = address(0xCAFE);
    address internal constant USER = address(0xDEAD);

    AuctionTokenMock internal token;
    Auction internal auction;

    bool internal finalizeResult = true;
    address internal lastBuyer;
    IControllerCallback.CallbackValue[] internal lastValues;

    function setUp() public {
        token = new AuctionTokenMock();
        auction = new Auction(_config());
        _setStartPrices();
    }

    function finalizeBuy(IControllerCallback.CallbackValue[] memory values, address buyer) external returns (bool) {
        delete lastValues;
        for (uint256 i = 0; i < values.length; i++) {
            lastValues.push(values[i]);
        }
        lastBuyer = buyer;
        return finalizeResult;
    }

    function test_constructorRevertsWhenControllerIsZero() public {
        IAuctionFactory.AuctionConfig memory config = _config();
        config.controller = address(0);

        vm.expectRevert(Auction.Auction__ControllerMisconfigured.selector);
        new Auction(config);
    }

    function test_constructorRevertsWhenTokenIsZero() public {
        IAuctionFactory.AuctionConfig memory config = _config();
        config.token = address(0);

        vm.expectRevert(Auction.Auction__TokenMisconfigured.selector);
        new Auction(config);
    }

    function test_constructorRevertsWhenLotSizeIsZero() public {
        IAuctionFactory.AuctionConfig memory config = _config();
        config.lotSize = 0;

        vm.expectRevert(Auction.Auction__LotSizeZero.selector);
        new Auction(config);
    }

    function test_constructorRevertsWhenEpochPeriodIsZero() public {
        IAuctionFactory.AuctionConfig memory config = _config();
        config.epochPeriod = 0;

        vm.expectRevert(Auction.Auction__EpochPeriodZero.selector);
        new Auction(config);
    }

    function test_constructorRevertsWhenAuctionScalarIsZero() public {
        IAuctionFactory.AuctionConfig memory config = _config();
        config.auctionScalar = 0;

        vm.expectRevert(Auction.Auction__AuctionScalarZero.selector);
        new Auction(config);
    }

    function test_constructorRevertsWhenMinAuctionScalarIsZero() public {
        IAuctionFactory.AuctionConfig memory config = _config();
        config.minAuctionScalar = 0;

        vm.expectRevert(Auction.Auction__MinAuctionScalarZero.selector);
        new Auction(config);
    }

    function test_constructorRevertsWhenMinScalarExceedsAuctionScalar() public {
        IAuctionFactory.AuctionConfig memory config = _config();
        config.minAuctionScalar = config.auctionScalar + 1;

        vm.expectRevert(Auction.Auction__ScalarBoundsInvalid.selector);
        new Auction(config);
    }

    function test_startRevertsWhenCallerIsNotController() public {
        vm.prank(USER);
        vm.expectRevert(Auction.Auction__NotController.selector);
        auction.start();
    }

    function test_startSetsEpochLotAndSnapshotsPrices() public {
        auction.start();

        assertEq(auction.currentEpoch(), 1);
        assertEq(auction.remainingLot(), LOT_SIZE);
        assertEq(auction.epochStart(), block.timestamp);

        address[] memory assets_ = new address[](2);
        uint256[] memory values_ = new uint256[](2);
        assets_[0] = ASSET;
        assets_[1] = SECOND_ASSET;
        values_[0] = 9e18;
        values_[1] = 9e18;
        token.setPrices(assets_, values_);

        IControllerCallback.CallbackValue[] memory prices = auction.getPrices(10e18);
        assertEq(prices.length, 2);
        assertEq(prices[0].asset, ASSET);
        assertEq(prices[0].value, 40e18);
        assertEq(prices[1].asset, SECOND_ASSET);
        assertEq(prices[1].value, 10e18);
    }

    function test_getRemainingReturnsTimeAndLotDuringAuction() public {
        auction.start();
        vm.warp(block.timestamp + 25);

        (uint256 timeRemaining, uint256 remainingLot) = auction.getRemaining();

        assertEq(timeRemaining, 75);
        assertEq(remainingLot, LOT_SIZE);
    }

    function test_getRemainingReturnsZeroTimeAfterExpiry() public {
        auction.start();
        vm.warp(block.timestamp + EPOCH_PERIOD + 1);

        (uint256 timeRemaining, uint256 remainingLot) = auction.getRemaining();

        assertEq(timeRemaining, 0);
        assertEq(remainingLot, LOT_SIZE);
    }

    function test_getPricesReturnsAuctionStartPricesAtEpochStart() public {
        auction.start();

        IControllerCallback.CallbackValue[] memory values = auction.getPrices(10e18);

        assertEq(values.length, 2);
        assertEq(values[0].asset, ASSET);
        assertEq(values[0].value, 40e18);
        assertEq(values[1].asset, SECOND_ASSET);
        assertEq(values[1].value, 10e18);
    }

    function test_getPricesUsesDecayedScalarMidAuction() public {
        auction.start();
        vm.warp(block.timestamp + 50);

        IControllerCallback.CallbackValue[] memory values = auction.getPrices(10e18);

        assertEq(values[0].value, 30e18);
        assertEq(values[1].value, 7.5e18);
    }

    function test_getPricesReturnsZeroValuesAfterAuctionExpiry() public {
        auction.start();
        vm.warp(block.timestamp + EPOCH_PERIOD + 1);

        IControllerCallback.CallbackValue[] memory values = auction.getPrices(10e18);

        assertEq(values.length, 2);
        assertEq(values[0].asset, address(0));
        assertEq(values[0].value, 0);
        assertEq(values[1].asset, address(0));
        assertEq(values[1].value, 0);
    }

    function test_bidRevertsWhenCallerIsNotController() public {
        auction.start();
        uint256 epochId = auction.currentEpoch();

        vm.startPrank(USER);
        vm.expectRevert(Auction.Auction__NotController.selector);
        auction.bid(10e18, block.timestamp, epochId, BUYER);
        vm.stopPrank();
    }

    function test_bidRevertsWhenDeadlinePassed() public {
        auction.start();
        uint256 epochId = auction.currentEpoch();
        uint256 deadline = block.timestamp == 0 ? 0 : block.timestamp - 1;

        vm.expectRevert(Auction.Auction__DeadlinePassed.selector);
        auction.bid(10e18, deadline, epochId, BUYER);
    }

    function test_bidRevertsWhenEpochIdDoesNotMatch() public {
        auction.start();

        vm.expectRevert(Auction.Auction__EpochIdMismatch.selector);
        auction.bid(10e18, block.timestamp, 0, BUYER);
    }

    function test_bidRevertsWhenAuctionHasNoRemainingLot() public {
        auction.start();
        uint256 epochId = auction.currentEpoch();
        auction.bid(LOT_SIZE, block.timestamp, epochId, BUYER);

        vm.expectRevert(Auction.Auction__AuctionFinished.selector);
        auction.bid(1, block.timestamp, epochId, BUYER);
    }

    function test_bidRevertsWhenAuctionHasExpired() public {
        auction.start();
        uint256 epochId = auction.currentEpoch();
        vm.warp(block.timestamp + EPOCH_PERIOD + 1);

        vm.expectRevert(Auction.Auction__AuctionFinished.selector);
        auction.bid(10e18, block.timestamp, epochId, BUYER);
    }

    function test_bidRevertsWhenControllerFinalizeFails() public {
        auction.start();
        finalizeResult = false;
        uint256 epochId = auction.currentEpoch();

        vm.expectRevert();
        auction.bid(10e18, block.timestamp, epochId, BUYER);

        assertEq(auction.remainingLot(), LOT_SIZE);
    }

    function test_bidFinalizesBuyAndReducesRemainingLot() public {
        auction.start();
        auction.bid(40e18, block.timestamp, auction.currentEpoch(), BUYER);

        assertEq(auction.remainingLot(), 60e18);
        assertEq(lastBuyer, BUYER);
        assertEq(lastValues.length, 2);
        assertEq(lastValues[0].asset, ASSET);
        assertEq(lastValues[0].value, 160e18);
        assertEq(lastValues[1].asset, SECOND_ASSET);
        assertEq(lastValues[1].value, 40e18);
    }

    function test_bidCapsPurchaseAmountAtRemainingLot() public {
        auction.start();
        auction.bid(120e18, block.timestamp, auction.currentEpoch(), BUYER);

        assertEq(auction.remainingLot(), 0);
        assertEq(lastValues.length, 2);
        assertEq(lastValues[0].value, 400e18);
        assertEq(lastValues[1].value, 100e18);
    }

    function _config() internal view returns (IAuctionFactory.AuctionConfig memory config) {
        config = IAuctionFactory.AuctionConfig({
            controller: address(this),
            token: address(token),
            lotSize: LOT_SIZE,
            epochPeriod: EPOCH_PERIOD,
            auctionScalar: AUCTION_SCALAR,
            minAuctionScalar: MIN_AUCTION_SCALAR
        });
    }

    function _setStartPrices() internal {
        address[] memory assets_ = new address[](2);
        uint256[] memory values_ = new uint256[](2);
        assets_[0] = ASSET;
        assets_[1] = SECOND_ASSET;
        values_[0] = 2e18;
        values_[1] = 0.5e18;
        token.setPrices(assets_, values_);
    }
}
