///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

interface IToken is IERC20 {
    struct AssetValue {
        address asset;
        uint256 value;
    }

    function prices() external view returns (AssetValue[] memory);
    function price(address) external view returns (uint256);
    function assets() external view returns (address[] memory);
    function addAsset(address) external;
    function burn(address, uint256) external;
    function redeem(address, uint256) external;
    function fulfillBorrow(address, address, uint256) external;
    function addBorrower(address) external;
    function MAX_SUPPLY() external view returns (uint256);
}
