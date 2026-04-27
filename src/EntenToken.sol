///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEntenToken} from "./interfaces/IEntenToken.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

contract EntenToken is ERC20, IEntenToken {
    address public immutable CONTROLLER;

    error Token__InvalidController();
    error Token__OnlyController();

    constructor(string memory name, string memory symbol, address controller) ERC20(name, symbol) {
        if (controller == address(0)) revert Token__InvalidController();
        CONTROLLER = controller;
    }

    modifier onlyController() {
        _onlyController();
        _;
    }

    function _onlyController() internal view {
        if (msg.sender != CONTROLLER) revert Token__OnlyController();
    }

    function mint(address account, uint256 amount) external onlyController {
        _mint(account, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external onlyController {
        _burn(account, amount);
    }
}
