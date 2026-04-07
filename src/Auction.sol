///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IAuction} from "./interfaces/IAuction.sol";
import {IAuctionFactory} from "./interfaces/factories/IAuctionFactory.sol";
import {IToken} from "./interfaces/IToken.sol";
import {IControllerCallback} from "./interfaces/IControllerCallback.sol";

contract Auction is IAuction {
    address public immutable CONTROLLER;
    address public immutable TOKEN;
    uint256 public immutable LOT_SIZE;
    uint256 public immutable EPOCH_PERIOD;
    uint256 public immutable AUCTION_SCALAR;
    uint256 public immutable MIN_AUCTION_SCALAR;

    uint256 public epochStart;
    uint256 public currentEpoch;
    uint256 public currentScalar;
    IToken.AssetValue[] private _startPrices;

    uint256 public remainingLot;

    error Auction__DeadlinePassed();
    error Auction__EpochIdMismatch();
    error Auction__AuctionFinished();
    error Auction__NotController();
    error Auction__ControllerMisconfigured();
    error Auction__TokenMisconfigured();
    error Auction__LotSizeZero();
    error Auction__EpochPeriodZero();
    error Auction__AuctionScalarZero();
    error Auction__ScalarBoundsInvalid();
    error Auction__MinAuctionScalarZero();

    constructor(IAuctionFactory.AuctionConfig memory config) {
        if (config.controller == address(0)) revert Auction__ControllerMisconfigured();
        if (config.token == address(0)) revert Auction__TokenMisconfigured();
        if (config.lotSize == 0) revert Auction__LotSizeZero();
        if (config.epochPeriod == 0) revert Auction__EpochPeriodZero();
        if (config.auctionScalar == 0) revert Auction__AuctionScalarZero();
        if (config.minAuctionScalar == 0) revert Auction__MinAuctionScalarZero();
        if (config.minAuctionScalar > config.auctionScalar) revert Auction__ScalarBoundsInvalid();

        CONTROLLER = config.controller;
        TOKEN = config.token;
        LOT_SIZE = config.lotSize;
        EPOCH_PERIOD = config.epochPeriod;
        AUCTION_SCALAR = config.auctionScalar;
        MIN_AUCTION_SCALAR = config.minAuctionScalar;
    }

    function bid(uint256 amount, uint256 deadline, uint256 epochId, address buyer) external {
        if (msg.sender != CONTROLLER) revert Auction__NotController();
        if (block.timestamp > deadline) revert Auction__DeadlinePassed();
        if (currentEpoch != epochId) revert Auction__EpochIdMismatch();
        if (remainingLot == 0 || block.timestamp > epochStart + EPOCH_PERIOD) revert Auction__AuctionFinished();
        uint256 buyAmount = amount > remainingLot ? remainingLot : amount;
        remainingLot -= buyAmount;
        IControllerCallback.CallbackValue[] memory values = getPrices(buyAmount);
        bool success = IControllerCallback(CONTROLLER).finalizeBuy(values, buyer);
        require(success);
    }

    function start() external {
        if (msg.sender != CONTROLLER) revert Auction__NotController();

        unchecked {
            currentEpoch++;
        }
        epochStart = block.timestamp;
        remainingLot = LOT_SIZE;
        delete _startPrices;
        IToken.AssetValue[] memory values = startPrices();
        for (uint256 i = 0; i < values.length; i++) {
            _startPrices.push(values[i]);
        }
    }

    function startPrices() internal view returns (IToken.AssetValue[] memory) {
        return IToken(TOKEN).prices();
    }

    function getRemaining() external view returns (uint256, uint256) {
        uint256 timeRemaining =
            block.timestamp > epochStart + EPOCH_PERIOD ? 0 : epochStart + EPOCH_PERIOD - block.timestamp;
        return (timeRemaining, remainingLot);
    }

    function getPrices(uint256 amount) public view returns (IControllerCallback.CallbackValue[] memory values) {
        IToken.AssetValue[] memory prices = _startPrices;
        values = new IControllerCallback.CallbackValue[](prices.length);
        uint256 timePassed = block.timestamp - epochStart;
        if (timePassed > EPOCH_PERIOD) {
            return values;
        }
        uint256 scalarDifference = AUCTION_SCALAR - MIN_AUCTION_SCALAR;
        uint256 scalar = AUCTION_SCALAR - scalarDifference * timePassed / EPOCH_PERIOD;
        for (uint256 i = 0; i < prices.length; i++) {
            uint256 amountPerToken = scalar * prices[i].value / 1e18;
            values[i] =
                IControllerCallback.CallbackValue({asset: prices[i].asset, value: (amountPerToken * amount / 1e18)});
        }
    }
}
