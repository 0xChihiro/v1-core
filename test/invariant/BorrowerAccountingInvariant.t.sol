///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "openzeppelin/mocks/token/ERC20Mock.sol";

import {Borrower} from "../../src/Borrower.sol";
import {IBorrower} from "../../src/interfaces/IBorrower.sol";
import {ITokenFactory} from "../../src/interfaces/factories/ITokenFactory.sol";
import {Token} from "../../src/Token.sol";

contract BorrowerViewHarness is Borrower {
    constructor(address controller, address token) Borrower(controller, token) {}

    function collateralOf(address account) external view returns (uint256) {
        return positions[account].collateral;
    }

    function borrowedOf(address account, address asset) external view returns (uint256) {
        return positions[account].borrowed[asset];
    }

    function maxBorrowOf(address account, address asset) external view returns (uint256) {
        return _maxBorrow(asset, positions[account].collateral);
    }
}

contract BorrowerHandler is Test {
    uint256 internal constant ACTOR_COUNT = 2;

    ERC20Mock internal asset;
    Token internal token;
    BorrowerViewHarness internal borrower;
    address[ACTOR_COUNT] internal actors;

    constructor(ERC20Mock asset_, Token token_, BorrowerViewHarness borrower_, address[ACTOR_COUNT] memory actors_) {
        asset = asset_;
        token = token_;
        borrower = borrower_;
        actors = actors_;

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            vm.prank(actors[i]);
            token.approve(address(borrower), type(uint256).max);

            vm.prank(actors[i]);
            asset.approve(address(borrower), type(uint256).max);
        }
    }

    function lock(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;

        amount = bound(amount, 0, balance);
        if (amount == 0) return;

        vm.prank(actor);
        borrower.lock(amount);
    }

    function unlock(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 collateral = borrower.collateralOf(actor);
        if (collateral == 0) return;

        amount = bound(amount, 0, collateral);
        if (amount == 0) return;

        vm.prank(actor);
        try borrower.unlock(amount) {} catch {}
    }

    function borrow(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 debt = borrower.borrowedOf(actor, address(asset));
        uint256 maxBorrow = borrower.maxBorrowOf(actor, address(asset));
        if (maxBorrow <= debt) return;

        amount = bound(amount, 0, maxBorrow - debt);
        if (amount == 0) return;

        vm.prank(actor);
        borrower.borrow(IBorrower.BorrowCall({asset: address(asset), amount: amount}));
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 debt = borrower.borrowedOf(actor, address(asset));
        uint256 balance = asset.balanceOf(actor);
        uint256 maxRepay = debt < balance ? debt : balance;
        if (maxRepay == 0) return;

        amount = bound(amount, 0, maxRepay);
        if (amount == 0) return;

        vm.prank(actor);
        borrower.repay(IBorrower.RepayCall({asset: address(asset), amount: amount}));
    }
}

contract BorrowerAccountingInvariant is StdInvariant, Test {
    uint256 internal constant PREMINT = 200e18;
    uint256 internal constant INITIAL_ASSET_BALANCE = 300e18;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    ERC20Mock internal asset;
    Token internal token;
    BorrowerViewHarness internal borrower;
    BorrowerHandler internal handler;

    function setUp() public {
        asset = new ERC20Mock();
        token = new Token(
            ITokenFactory.TokenConfig({
                name: "Enten",
                symbol: "ENT",
                controller: address(this),
                maxSupply: 1_000e18,
                preMintReceiver: ALICE,
                preMintAmount: PREMINT
            })
        );
        borrower = new BorrowerViewHarness(address(this), address(token));

        asset.mint(address(this), INITIAL_ASSET_BALANCE);
        asset.transfer(address(token), INITIAL_ASSET_BALANCE);
        token.addBorrower(address(borrower));
        token.addAsset(address(asset));
        borrower.addBorrowableAsset(address(asset));

        vm.prank(ALICE);
        token.transfer(BOB, PREMINT / 2);

        handler = new BorrowerHandler(asset, token, borrower, [ALICE, BOB]);
        targetContract(address(handler));
    }

    function invariant_underlyingPlusDebtIsConserved() public view {
        assertEq(asset.balanceOf(address(token)) + borrower.totalBorrows(address(asset)), INITIAL_ASSET_BALANCE);
    }

    function invariant_totalSupplyIsStableAcrossBorrowFlows() public view {
        assertEq(token.totalSupply(), PREMINT);
    }

    function invariant_eachUserDebtNeverExceedsCurrentCollateralCapacity() public view {
        assertLe(borrower.borrowedOf(ALICE, address(asset)), borrower.maxBorrowOf(ALICE, address(asset)));
        assertLe(borrower.borrowedOf(BOB, address(asset)), borrower.maxBorrowOf(BOB, address(asset)));
    }
}
