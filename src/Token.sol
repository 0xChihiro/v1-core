///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IToken} from "./interfaces/IToken.sol";
import {ITokenFactory} from "./interfaces/factories/ITokenFactory.sol";
import {IBorrower} from "./interfaces/IBorrower.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

contract Token is ERC20, IToken {
    using SafeERC20 for IToken;
    uint256 public immutable MAX_SUPPLY;
    address public immutable CONTROLLER;

    mapping(address => bool) private _registeredAssets;
    address[] private _assets;
    address public borrower;

    event Token__Mint(address indexed to, uint256 amount);
    event Token__Burn(address indexed from, uint256 amount);
    event Token__Redeem(address indexed to, uint256 redeemedAmount, IToken.AssetValue[] values);
    event Token__FulfillBorrow(address indexed asset, address indexed to, uint256 amount);
    event Token__AddAsset(address indexed asset);
    event Token__AddBorrower(address indexed borrower);

    error Token__AssetAlreadyAdded();
    error Token__BorrowerInitialized();
    error Token__OnlyBorrower();
    error Token__BorrowerZeroAddress();
    error Token__BurnBalance();
    error Token__ControllerMisconfigured();
    error Token__ControllerOnly();
    error Token__MaxSupply();
    error Token__MaxSupplyZero();
    error Token__RedeemBalance();
    error Token__AssetZeroAddress();
    error Token__AssetNotFunded();
    error Token__NameEmpty();
    error Token__SymbolEmpty();
    error Token__PreMintMisconfigured();

    constructor(ITokenFactory.TokenConfig memory config) ERC20(config.name, config.symbol) {
        if (bytes(config.name).length == 0) revert Token__NameEmpty();
        if (bytes(config.symbol).length == 0) revert Token__SymbolEmpty();
        if (config.maxSupply == 0) revert Token__MaxSupplyZero();
        if (config.controller == address(0)) revert Token__ControllerMisconfigured();
        if (
            config.preMintReceiver == address(0) || config.preMintAmount == 0 || config.preMintAmount > config.maxSupply
        ) revert Token__PreMintMisconfigured();

        _mint(config.preMintReceiver, config.preMintAmount);

        MAX_SUPPLY = config.maxSupply;
        CONTROLLER = config.controller;
    }

    function mint(address account, uint256 amount) external {
        if (msg.sender != CONTROLLER) revert Token__ControllerOnly();
        if (totalSupply() + amount > MAX_SUPPLY) revert Token__MaxSupply();

        _mint(account, amount);
        emit Token__Mint(account, amount);
    }

    function redeem(address account, uint256 amount) external {
        if (msg.sender != CONTROLLER) revert Token__ControllerOnly();
        if (amount > balanceOf(account)) revert Token__RedeemBalance();
        IToken.AssetValue[] memory values = prices();
        for (uint256 i = 0; i < values.length; i++) {
            values[i].value = amount * values[i].value / 1e18;
        }
        _burn(account, amount);
        for (uint256 i = 0; i < values.length; i++) {
            bool success = IToken(values[i].asset).transfer(account, values[i].value);
            require(success, "Redeem Transfer Failed");
        }
        emit Token__Redeem(account, amount, values);
    }

    function burn(address account, uint256 amount) external {
        if (msg.sender != CONTROLLER) revert Token__ControllerOnly();
        if (balanceOf(account) < amount) revert Token__BurnBalance();
        _burn(account, amount);
        emit Token__Burn(account, amount);
    }

    function addAsset(address asset) external {
        if (msg.sender != CONTROLLER) revert Token__ControllerOnly();
        if (_registeredAssets[asset]) revert Token__AssetAlreadyAdded();
        if (asset == address(0) || asset == address(this)) revert Token__AssetZeroAddress();
        if (_price(asset) == 0) revert Token__AssetNotFunded();
        _registeredAssets[asset] = true;
        _assets.push(asset);
        emit Token__AddAsset(asset);
    }

    function addBorrower(address _borrower) external {
        if (msg.sender != CONTROLLER) revert Token__ControllerOnly();
        if (_borrower == address(0)) revert Token__BorrowerZeroAddress();
        if (borrower != address(0)) revert Token__BorrowerInitialized();
        borrower = _borrower;
        emit Token__AddBorrower(_borrower);
    }

    function fulfillBorrow(address asset, address to, uint256 amount) external {
        if (msg.sender != borrower) revert Token__OnlyBorrower();
        IToken(asset).safeTransfer(to, amount);
        emit Token__FulfillBorrow(asset, to, amount);
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function prices() public view returns (IToken.AssetValue[] memory values) {
        values = new IToken.AssetValue[](_assets.length);
        uint256 supply = totalSupply();
        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 value;
            if (supply != 0) {
                uint256 borrowed = borrower == address(0) ? 0 : IBorrower(borrower).totalBorrows(_assets[i]);
                value = (IToken(_assets[i]).balanceOf(address(this)) + borrowed) * 1e18 / supply;
            }
            values[i] = IToken.AssetValue({asset: _assets[i], value: value});
        }
    }

    function price(address asset) external view returns (uint256) {
        return _price(asset);
    }

    function _price(address asset) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        uint256 borrowed = borrower == address(0) ? 0 : IBorrower(borrower).totalBorrows(asset);
        return (IToken(asset).balanceOf(address(this)) + borrowed) * 1e18 / supply;
    }
}
