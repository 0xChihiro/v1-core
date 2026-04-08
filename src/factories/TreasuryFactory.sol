///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Treasury} from "../Treasury.sol";
import {ITreasuryFactory} from "../interfaces/factories/ITreasuryFactory.sol";

contract TreasuryFactory is ITreasuryFactory {
    constructor() {}

    function createTreasury() external returns (address) {
        return address(new Treasury());
    }
}
