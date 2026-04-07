///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface ITokenFactory {
    struct TokenConfig {
        string name;
        string symbol;
        address controller;
        uint256 maxSupply;
    }

    function createToken(TokenConfig memory config) external returns (address);
}
