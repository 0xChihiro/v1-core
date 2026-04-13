///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IToken} from "./interfaces/IToken.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

contract Collector {
    using SafeERC20 for IToken;
    enum CollectorType {
        Protocol,
        Team
    }

    struct DistributeCall {
        address asset;
        address to;
        uint256 amount;
    }
    CollectorType public immutable TYPE;
    address public token;

    error Collector__TokenInitialized();
    error Collector__TokenMisconfigured();

    constructor() {}

    function swap() external {}

    function distribute(DistributeCall[] calldata calls) external {
        CollectorType _type = TYPE;
        for (uint256 i = 0; i < calls.length; i++) {
            if (_type == CollectorType.Protocol) {
                IToken(calls[i].asset).safeTransfer(token, calls[i].amount);
            } else {
                IToken(calls[i].asset).safeTransfer(calls[i].to, calls[i].amount);
            }
        }
    }

    function addToken(address _token) external {
        if (token != address(0)) revert Collector__TokenInitialized();
        if (_token == address(0)) revert Collector__TokenMisconfigured();
        token = _token;
    }
}
