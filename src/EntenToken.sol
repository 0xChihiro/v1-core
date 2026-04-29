///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEntenToken} from "./interfaces/IEntenToken.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

contract EntenToken is ERC20, IEntenToken {
    address public immutable CONTROLLER;
    uint256 public immutable MAX_SUPPLY;

    error Token__InvalidController();
    error Token__OnlyController();
    error Token__PreMineMisconfigured();
    error Token__MaxSupply();

    constructor(
        string memory name,
        string memory symbol,
        address controller,
        address preMineAddress,
        uint256 preMineAmount,
        uint256 maxSupply
    ) ERC20(name, symbol) {
        if (controller == address(0)) revert Token__InvalidController();
        if (maxSupply == 0) revert Token__MaxSupply();

        MAX_SUPPLY = maxSupply;
        CONTROLLER = controller;

        if (preMineAmount > 0) {
            if (preMineAddress == address(0) || preMineAmount > maxSupply) {
                revert Token__PreMineMisconfigured();
            }
            _mint(preMineAddress, preMineAmount);
        }
    }

    modifier onlyController() {
        _onlyController();
        _;
    }

    function _onlyController() internal view {
        if (msg.sender != CONTROLLER) revert Token__OnlyController();
    }

    function mint(address account, uint256 amount) external onlyController {
        if (totalSupply() + amount > MAX_SUPPLY) revert Token__MaxSupply();
        _mint(account, amount);
    }

    /// @dev burns are also restricted because they may effect other aspects of the system
    /// depending on the creators configuration so must be handled by the controller.
    function burnFrom(address account, uint256 amount) external onlyController {
        _burn(account, amount);
    }
}
