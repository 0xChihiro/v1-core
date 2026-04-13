///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {ERC20Mock} from "openzeppelin/mocks/token/ERC20Mock.sol";
import {ERC20ReturnFalseMock} from "openzeppelin/mocks/token/ERC20ReturnFalseMock.sol";

import {IBorrower} from "../src/interfaces/IBorrower.sol";
import {IToken} from "../src/interfaces/IToken.sol";
import {ITokenFactory} from "../src/interfaces/factories/ITokenFactory.sol";
import {Token} from "../src/Token.sol";

contract BorrowerMock is IBorrower {
    mapping(address => uint256) public totalBorrows;
    function addBorrowableAsset(address) public {}

    function setTotalBorrows(address asset, uint256 amount) external {
        totalBorrows[asset] = amount;
    }
}

contract ReturnFalseAsset is ERC20ReturnFalseMock {
    constructor() ERC20("ReturnFalse", "RF") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract TokenTest is Test {
    uint256 internal constant SUPPLY = 100e18;
    uint256 internal constant ASSET_BALANCE = 200e18;
    uint256 internal constant BORROWED = 40e18;
    uint256 internal constant SMALL_MAX_SUPPLY = 10e18;

    address internal constant USER = address(0xB0B);
    address internal constant RECEIVER = address(0xCAFE);
    address internal constant BORROWER = address(0xBEEF);

    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;
    Token internal token;
    BorrowerMock internal borrower;

    function setUp() public {
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();
        borrower = new BorrowerMock();

        token = new Token(_config(type(uint256).max));

        asset.mint(address(this), ASSET_BALANCE);
        assertTrue(asset.transfer(address(token), ASSET_BALANCE));
    }

    function test_constructorRevertsWhenNameIsEmpty() public {
        ITokenFactory.TokenConfig memory config = _config(type(uint256).max);
        config.name = "";

        vm.expectRevert(Token.Token__NameEmpty.selector);
        new Token(config);
    }

    function test_constructorRevertsWhenSymbolIsEmpty() public {
        ITokenFactory.TokenConfig memory config = _config(type(uint256).max);
        config.symbol = "";

        vm.expectRevert(Token.Token__SymbolEmpty.selector);
        new Token(config);
    }

    function test_constructorRevertsWhenMaxSupplyIsZero() public {
        ITokenFactory.TokenConfig memory config = _config(0);

        vm.expectRevert(Token.Token__MaxSupplyZero.selector);
        new Token(config);
    }

    function test_constructorRevertsWhenControllerIsZero() public {
        ITokenFactory.TokenConfig memory config = _config(type(uint256).max);
        config.controller = address(0);

        vm.expectRevert(Token.Token__ControllerMisconfigured.selector);
        new Token(config);
    }

    function test_mintRevertsWhenCallerIsNotController() public {
        vm.prank(USER);
        vm.expectRevert(Token.Token__ControllerOnly.selector);
        token.mint(USER, 1);
    }

    function test_mintRevertsWhenMintExceedsMaxSupply() public {
        Token limitedToken = new Token(_config(SMALL_MAX_SUPPLY));

        vm.expectRevert(Token.Token__MaxSupply.selector);
        limitedToken.mint(USER, SMALL_MAX_SUPPLY + 1);
    }

    function test_mintSucceedsWhenCalledByControllerWithinCap() public {
        token.mint(RECEIVER, 5e18);

        assertEq(token.balanceOf(RECEIVER), 5e18);
        assertEq(token.totalSupply(), SUPPLY + 5e18);
    }

    function test_redeemRevertsWhenCallerIsNotController() public {
        vm.prank(USER);
        vm.expectRevert(Token.Token__ControllerOnly.selector);
        token.redeem(USER, 1);
    }

    function test_redeemRevertsWhenAmountExceedsBalance() public {
        vm.expectRevert(Token.Token__RedeemBalance.selector);
        token.redeem(USER, SUPPLY + 1);
    }

    function test_redeemTransfersAssetsUsingCurrentRedemptionMath() public {
        token.addAsset(address(asset));
        uint256 redeemAmount = 10e18;
        uint256 expectedPayout = redeemAmount * (ASSET_BALANCE * 1e18 / SUPPLY) / 1e18;

        token.redeem(USER, redeemAmount);

        assertEq(token.balanceOf(USER), SUPPLY - redeemAmount);
        assertEq(asset.balanceOf(USER), expectedPayout);
        assertEq(asset.balanceOf(address(token)), ASSET_BALANCE - expectedPayout);
    }

    function test_redeemRevertsWhenAssetTransferReturnsFalse() public {
        ReturnFalseAsset falseAsset = new ReturnFalseAsset();
        falseAsset.mint(address(token), ASSET_BALANCE);
        token.addAsset(address(falseAsset));

        vm.expectRevert(bytes("Redeem Transfer Failed"));
        token.redeem(USER, 1e18);

        assertEq(token.balanceOf(USER), SUPPLY);
        assertEq(falseAsset.balanceOf(address(token)), ASSET_BALANCE);
    }

    function test_burnRevertsWhenCallerIsNotController() public {
        vm.prank(USER);
        vm.expectRevert(Token.Token__ControllerOnly.selector);
        token.burn(USER, 1);
    }

    function test_burnRevertsWhenAccountBalanceIsTooLow() public {
        vm.expectRevert(Token.Token__BurnBalance.selector);
        token.burn(RECEIVER, 1);
    }

    function test_burnReducesBalanceAndSupply() public {
        token.burn(USER, 10e18);

        assertEq(token.balanceOf(USER), SUPPLY - 10e18);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_addAssetRevertsWhenCallerIsNotController() public {
        vm.prank(USER);
        vm.expectRevert(Token.Token__ControllerOnly.selector);
        token.addAsset(address(asset));
    }

    function test_addAssetRevertsWhenAssetIsZeroAddress() public {
        vm.expectRevert(Token.Token__AssetZeroAddress.selector);
        token.addAsset(address(0));
    }

    function test_addAssetRevertsWhenAssetIsToken() public {
        vm.expectRevert(Token.Token__AssetZeroAddress.selector);
        token.addAsset(address(token));
    }

    function test_addAssetRevertsWhenAssetAlreadyAdded() public {
        token.addAsset(address(asset));

        vm.expectRevert(Token.Token__AssetAlreadyAdded.selector);
        token.addAsset(address(asset));
    }

    function test_addAssetRevertsWhenAssetHasNoBacking() public {
        ERC20Mock unfundedAsset = new ERC20Mock();

        vm.expectRevert(Token.Token__AssetNotFunded.selector);
        token.addAsset(address(unfundedAsset));
    }

    function test_addAssetStoresAssetAndAssetsGetterReturnsIt() public {
        token.addAsset(address(asset));

        address[] memory assets_ = token.assets();

        assertEq(assets_.length, 1);
        assertEq(assets_[0], address(asset));
    }

    function test_addBorrowerRevertsWhenCallerIsNotController() public {
        vm.prank(USER);
        vm.expectRevert(Token.Token__ControllerOnly.selector);
        token.addBorrower(BORROWER);
    }

    function test_addBorrowerRevertsWhenBorrowerIsZero() public {
        vm.expectRevert(Token.Token__BorrowerZeroAddress.selector);
        token.addBorrower(address(0));
    }

    function test_addBorrowerRevertsWhenAlreadyInitialized() public {
        token.addBorrower(BORROWER);

        vm.expectRevert(Token.Token__BorrowerInitialized.selector);
        token.addBorrower(RECEIVER);
    }

    function test_addBorrowerStoresBorrowerAddress() public {
        token.addBorrower(BORROWER);

        assertEq(token.borrower(), BORROWER);
    }

    function test_fulfillBorrowRevertsWhenCallerIsNotBorrower() public {
        token.addBorrower(address(borrower));
        token.addAsset(address(asset));

        vm.expectRevert(Token.Token__OnlyBorrower.selector);
        token.fulfillBorrow(address(asset), RECEIVER, 1e18);
    }

    function test_fulfillBorrowTransfersAssetWhenCallerIsBorrower() public {
        token.addBorrower(address(borrower));
        token.addAsset(address(asset));

        vm.prank(address(borrower));
        token.fulfillBorrow(address(asset), RECEIVER, 5e18);

        assertEq(asset.balanceOf(RECEIVER), 5e18);
        assertEq(asset.balanceOf(address(token)), ASSET_BALANCE - 5e18);
    }

    function test_addAssetAndPriceWorkBeforeBorrowerInitialized() public {
        token.addAsset(address(asset));

        IToken.AssetValue[] memory values = token.prices();

        assertEq(values.length, 1);
        assertEq(values[0].asset, address(asset));
        assertEq(values[0].value, 2e18);
        assertEq(token.price(address(asset)), 2e18);
    }

    function test_priceRemainsConstantWhenBorrowedAmountLeavesToken() public {
        token.addBorrower(address(borrower));
        token.addAsset(address(asset));

        uint256 priceBeforeBorrow = token.price(address(asset));

        vm.prank(address(token));
        assertTrue(asset.transfer(RECEIVER, BORROWED));
        borrower.setTotalBorrows(address(asset), BORROWED);

        uint256 priceAfterBorrow = token.price(address(asset));
        IToken.AssetValue[] memory values = token.prices();

        assertEq(priceBeforeBorrow, 2e18);
        assertEq(priceAfterBorrow, priceBeforeBorrow);
        assertEq(values.length, 1);
        assertEq(values[0].value, priceBeforeBorrow);
    }

    function test_pricesReturnZeroWhenSupplyIsZero() public {
        token.addAsset(address(asset));
        token.burn(USER, SUPPLY);

        IToken.AssetValue[] memory values = token.prices();

        assertEq(values.length, 1);
        assertEq(values[0].asset, address(asset));
        assertEq(values[0].value, 0);
        assertEq(token.price(address(asset)), 0);
    }

    function test_pricesReturnsAllConfiguredAssets() public {
        secondAsset.mint(address(this), 50e18);
        assertTrue(secondAsset.transfer(address(token), 50e18));

        token.addAsset(address(asset));
        token.addAsset(address(secondAsset));

        IToken.AssetValue[] memory values = token.prices();

        assertEq(values.length, 2);
        assertEq(values[0].asset, address(asset));
        assertEq(values[0].value, 2e18);
        assertEq(values[1].asset, address(secondAsset));
        assertEq(values[1].value, 0.5e18);
    }

    function _config(uint256 maxSupply) internal view returns (ITokenFactory.TokenConfig memory config) {
        config = ITokenFactory.TokenConfig({
            name: "Enten",
            symbol: "ENT",
            controller: address(this),
            maxSupply: maxSupply,
            preMintReceiver: USER,
            preMintAmount: maxSupply < SUPPLY ? maxSupply : SUPPLY
        });
    }
}
