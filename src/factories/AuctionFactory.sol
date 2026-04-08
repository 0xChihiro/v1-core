///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Auction} from "../Auction.sol";
import {IAuctionFactory} from "../interfaces/factories/IAuctionFactory.sol";

contract AuctionFactory is IAuctionFactory {
    constructor() {}

    function createAuction(IAuctionFactory.AuctionConfig calldata config) external returns (address) {
        return address(new Auction(config));
    }
}
