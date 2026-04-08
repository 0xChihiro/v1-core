///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Token} from "../Token.sol";
import {ITokenFactory} from "../interfaces/factories/ITokenFactory.sol";

contract TokenFactory is ITokenFactory {
    constructor() {}

    function createToken(ITokenFactory.TokenConfig calldata config) external returns (address) {
        return address(new Token(config));
    }
}
