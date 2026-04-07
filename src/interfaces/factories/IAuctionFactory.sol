///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IAuctionFactory {
    struct AuctionConfig {
        address controller;
        address token;
        uint256 lotSize;
        uint256 epochPeriod;
        uint256 auctionScalar;
        uint256 minAuctionScalar;
    }

    function createAuction(AuctionConfig memory config) external returns (address);
}
