///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBorrowerFactory} from "../interfaces/factories/IBorrowerFactory.sol";
import {Borrower} from "../Borrower.sol";

contract BorrowerFactory is IBorrowerFactory {
    constructor() {}

    function createBorrower(IBorrowerFactory.BorrowerConfig calldata config) external returns (address) {
        return address(new Borrower(config.controller, config.token));
    }
}
