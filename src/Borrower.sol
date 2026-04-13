///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBorrower} from "./interfaces/IBorrower.sol";
import {IToken} from "./interfaces/IToken.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

contract Borrower is IBorrower {
    using SafeERC20 for IToken;
    address public immutable TOKEN;
    address public immutable CONTROLLER;

    mapping(address => IBorrower.Position) internal positions;
    mapping(address => uint256) public totalBorrows;
    mapping(address => bool) private _borrowableAssets;
    address[] public borrowableAssets;

    error Borrower__InvalidWithdrawlAmount();
    error Borrower__Misconfigured();
    error Borrower__TooMuchDebt();
    error Borrower__ExceedsBorrowingCapacity();
    error Borrower__AssetNotBorrowable();
    error Borrower__ControllerOnly();
    error Borrower__AssetAddressZero();

    constructor(address controller, address token) {
        if (controller == address(0) || token == address(0)) revert Borrower__Misconfigured();

        CONTROLLER = controller;
        TOKEN = token;
    }

    function lock(uint256 amount) external {
        IToken(TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        positions[msg.sender].collateral += amount;
    }

    function unlock(uint256 amount) external {
        IBorrower.Position storage position = positions[msg.sender];
        if (amount > position.collateral) revert Borrower__InvalidWithdrawlAmount();

        uint256 afterUnlockAmount = position.collateral - amount;
        for (uint256 i = 0; i < borrowableAssets.length; i++) {
            address asset = borrowableAssets[i];
            if (position.borrowed[asset] > _maxBorrow(asset, afterUnlockAmount)) revert Borrower__TooMuchDebt();
        }

        position.collateral = afterUnlockAmount;
        IToken(TOKEN).safeTransfer(msg.sender, amount);
    }

    function addBorrowableAsset(address asset) external {
        if (msg.sender != CONTROLLER) revert Borrower__ControllerOnly();
        if (asset == address(0)) revert Borrower__AssetAddressZero();
        if (_borrowableAssets[asset]) return;
        _borrowableAssets[asset] = true;
        borrowableAssets.push(asset);
    }

    function borrow(IBorrower.BorrowCall memory call) public {
        if (!_borrowableAssets[call.asset]) revert Borrower__AssetNotBorrowable();
        IBorrower.Position storage position = positions[msg.sender];
        uint256 newBorrowedAmount = position.borrowed[call.asset] + call.amount;
        if (newBorrowedAmount > _maxBorrow(call.asset, position.collateral)) {
            revert Borrower__ExceedsBorrowingCapacity();
        }
        position.borrowed[call.asset] = newBorrowedAmount;
        totalBorrows[call.asset] += call.amount;
        IToken(TOKEN).fulfillBorrow(call.asset, msg.sender, call.amount);
    }

    function borrowMultiple(IBorrower.BorrowCall[] memory calls) external {
        for (uint256 i = 0; i < calls.length; i++) {
            borrow(calls[i]);
        }
    }

    function repay(IBorrower.RepayCall memory call) public {
        if (!_borrowableAssets[call.asset]) revert Borrower__AssetNotBorrowable();
        IBorrower.Position storage position = positions[msg.sender];
        uint256 repayment = position.borrowed[call.asset] > call.amount ? call.amount : position.borrowed[call.asset];
        IToken(call.asset).safeTransferFrom(msg.sender, TOKEN, repayment);
        position.borrowed[call.asset] -= repayment;
        totalBorrows[call.asset] -= repayment;
    }

    function repayMultiple(IBorrower.RepayCall[] memory calls) external {
        for (uint256 i = 0; i < calls.length; i++) {
            repay(calls[i]);
        }
    }

    function _maxBorrow(address borrowedAsset, uint256 amount) internal view returns (uint256) {
        uint256 perToken = IToken(TOKEN).price(borrowedAsset);
        return amount * perToken / 1e18;
    }
}
