///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IControllerFactory {
    struct ControllerConfig {
        address admin;
        address teamCollector;
        uint256 backingFee;
        uint256 treasuryFee;
        uint256 teamFee;
        uint256 maxAssets;
        address auctionFactory;
        address tokenFactory;
        address treasuryFactory;
    }
}
