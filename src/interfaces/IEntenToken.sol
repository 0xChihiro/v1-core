///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IEntenToken is IERC20 {
    function CONTROLLER() external view returns (address);
    function mint(address account, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}
