///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "openzeppelin/contracts/interfaces/draft-IERC6093.sol";

interface IToken is IERC20Metadata, IERC20Errors {
    function CONTROLLER() external view returns (address);
    function MAX_SUPPLY() external view returns (uint256);
    function mint(address account, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}
