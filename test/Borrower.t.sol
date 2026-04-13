///SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ERC20Mock} from "openzeppelin/mocks/token/ERC20Mock.sol";

import {Borrower} from "../src/Borrower.sol";
import {IBorrower} from "../src/interfaces/IBorrower.sol";
import {IToken} from "../src/interfaces/IToken.sol";
import {ITokenFactory} from "../src/interfaces/factories/ITokenFactory.sol";
import {Token} from "../src/Token.sol";

contract BorrowerHarness is Borrower {
    constructor(address controller, address token) Borrower(controller, token) {}

    function setBorrowed(address account, address asset, uint256 amount) external {
        positions[account].borrowed[asset] = amount;
    }
}

contract MockBorrowToken is ERC20, IToken {
    uint256 public constant MAX_SUPPLY = type(uint256).max;

    address public borrower;

    mapping(address => uint256) private _prices;
    mapping(address => bool) private _knownAssets;
    address[] private _assets;

    error MockBorrowToken__OnlyBorrower();

    constructor() ERC20("Enten", "ENT") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setBorrower(address account) external {
        borrower = account;
    }

    function setPrice(address asset, uint256 value) external {
        _prices[asset] = value;
        if (!_knownAssets[asset]) {
            _knownAssets[asset] = true;
            _assets.push(asset);
        }
    }

    function prices() external view returns (IToken.AssetValue[] memory values) {
        values = new IToken.AssetValue[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            values[i] = IToken.AssetValue({asset: _assets[i], value: _prices[_assets[i]]});
        }
    }

    function price(address asset) external view returns (uint256) {
        return _prices[asset];
    }

    function assets() external view returns (address[] memory) {
        return _assets;
    }

    function addAsset(address asset) external {
        if (_knownAssets[asset]) return;
        _knownAssets[asset] = true;
        _assets.push(asset);
    }

    function addBorrower(address account) external {
        borrower = account;
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function redeem(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function fulfillBorrow(address asset, address to, uint256 amount) external {
        if (msg.sender != borrower) revert MockBorrowToken__OnlyBorrower();

        bool success = IERC20(asset).transfer(to, amount);
        require(success, "Borrow transfer failed");
    }
}

contract BorrowerFlowHarness is Borrower {
    constructor(address controller, address token) Borrower(controller, token) {}

    function borrowedOf(address account, address asset) external view returns (uint256) {
        return positions[account].borrowed[asset];
    }

    function collateralOf(address account) external view returns (uint256) {
        return positions[account].collateral;
    }
}

contract BorrowerUnlockTest is Test {
    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant ASSET_BALANCE = 200e18;
    uint256 internal constant SECOND_ASSET_BALANCE = 50e18;

    address internal constant USER = address(0xB0B);

    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;
    Token internal token;
    BorrowerHarness internal borrower;

    function setUp() public {
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();

        ITokenFactory.TokenConfig memory config = ITokenFactory.TokenConfig({
            name: "Enten",
            symbol: "ENT",
            controller: address(this),
            maxSupply: type(uint256).max,
            preMintReceiver: USER,
            preMintAmount: COLLATERAL
        });

        token = new Token(config);
        borrower = new BorrowerHarness(address(this), address(token));

        asset.mint(address(this), ASSET_BALANCE);
        secondAsset.mint(address(this), SECOND_ASSET_BALANCE);
        assertTrue(asset.transfer(address(token), ASSET_BALANCE));
        assertTrue(secondAsset.transfer(address(token), SECOND_ASSET_BALANCE));
        token.addAsset(address(asset));
        token.addAsset(address(secondAsset));
        borrower.addBorrowableAsset(address(asset));
        borrower.addBorrowableAsset(address(secondAsset));

        vm.prank(USER);
        token.approve(address(borrower), type(uint256).max);

        vm.prank(USER);
        borrower.lock(COLLATERAL);
    }

    function test_unlockRevertsWhenDebtExceedsBorrowableAfterWithdraw() public {
        borrower.setBorrowed(USER, address(asset), 161e18);

        vm.prank(USER);
        vm.expectRevert(Borrower.Borrower__TooMuchDebt.selector);
        borrower.unlock(20e18);
    }

    function test_unlockAllowsWithdrawWhenDebtFitsBorrowableAfterWithdraw() public {
        borrower.setBorrowed(USER, address(asset), 160e18);

        vm.prank(USER);
        borrower.unlock(20e18);

        assertEq(token.balanceOf(USER), 20e18);
        assertEq(token.balanceOf(address(borrower)), 80e18);
    }

    function test_unlockRevertsWhenAnyBorrowedAssetExceedsBorrowableAfterWithdraw() public {
        borrower.setBorrowed(USER, address(asset), 100e18);
        borrower.setBorrowed(USER, address(secondAsset), 41e18);

        vm.prank(USER);
        vm.expectRevert(Borrower.Borrower__TooMuchDebt.selector);
        borrower.unlock(20e18);
    }

    function test_unlockRevertsWhenAmountExceedsCollateral() public {
        vm.prank(USER);
        vm.expectRevert(Borrower.Borrower__InvalidWithdrawlAmount.selector);
        borrower.unlock(COLLATERAL + 1);
    }
}

contract BorrowerRedemptionLiquidityTest is Test {
    uint256 internal constant TOTAL_SUPPLY = 100e18;
    uint256 internal constant LOCKED_SUPPLY = 50e18;
    uint256 internal constant UNLOCKED_SUPPLY = 50e18;
    uint256 internal constant ASSET_BACKING = 100e18;

    address internal constant BORROWER_ACCOUNT = address(0xA11CE);
    address internal constant UNLOCKED_HOLDER = address(0xB0B);

    ERC20Mock internal asset;
    Token internal token;
    Borrower internal borrower;

    function setUp() public {
        asset = new ERC20Mock();

        ITokenFactory.TokenConfig memory config = ITokenFactory.TokenConfig({
            name: "Enten",
            symbol: "ENT",
            controller: address(this),
            maxSupply: type(uint256).max,
            preMintReceiver: BORROWER_ACCOUNT,
            preMintAmount: TOTAL_SUPPLY
        });

        token = new Token(config);
        borrower = new Borrower(address(this), address(token));

        asset.mint(address(this), ASSET_BACKING);
        assertTrue(asset.transfer(address(token), ASSET_BACKING));

        token.addBorrower(address(borrower));
        token.addAsset(address(asset));
        borrower.addBorrowableAsset(address(asset));

        vm.prank(BORROWER_ACCOUNT);
        assertTrue(token.transfer(UNLOCKED_HOLDER, UNLOCKED_SUPPLY));

        vm.prank(BORROWER_ACCOUNT);
        token.approve(address(borrower), type(uint256).max);
    }

    function test_unlockedSupplyCanRedeemAfterBorrowerBorrowsLockedShare() public {
        vm.prank(BORROWER_ACCOUNT);
        borrower.lock(LOCKED_SUPPLY);

        vm.prank(BORROWER_ACCOUNT);
        borrower.borrow(IBorrower.BorrowCall({asset: address(asset), amount: LOCKED_SUPPLY}));

        assertEq(asset.balanceOf(address(token)), UNLOCKED_SUPPLY);
        assertEq(borrower.totalBorrows(address(asset)), LOCKED_SUPPLY);

        vm.prank(BORROWER_ACCOUNT);
        vm.expectRevert(Borrower.Borrower__TooMuchDebt.selector);
        borrower.unlock(LOCKED_SUPPLY);

        token.redeem(UNLOCKED_HOLDER, UNLOCKED_SUPPLY);

        assertEq(token.balanceOf(UNLOCKED_HOLDER), 0);
        assertEq(asset.balanceOf(UNLOCKED_HOLDER), UNLOCKED_SUPPLY);
        assertEq(asset.balanceOf(address(token)), 0);
        assertEq(borrower.totalBorrows(address(asset)), LOCKED_SUPPLY);
    }

    function test_borrowCannotConsumeLiquidityNeededByUnlockedSupply() public {
        vm.prank(BORROWER_ACCOUNT);
        borrower.lock(LOCKED_SUPPLY);

        vm.prank(BORROWER_ACCOUNT);
        vm.expectRevert(Borrower.Borrower__ExceedsBorrowingCapacity.selector);
        borrower.borrow(IBorrower.BorrowCall({asset: address(asset), amount: LOCKED_SUPPLY + 1}));

        assertEq(asset.balanceOf(address(token)), ASSET_BACKING);
        assertEq(asset.balanceOf(BORROWER_ACCOUNT), 0);
        assertEq(borrower.totalBorrows(address(asset)), 0);
    }
}

contract BorrowerFlowTest is Test {
    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant ASSET_PRICE = 2e18;
    uint256 internal constant SECOND_ASSET_PRICE = 0.5e18;
    uint256 internal constant ASSET_LIQUIDITY = 500e18;
    uint256 internal constant SECOND_ASSET_LIQUIDITY = 200e18;

    address internal constant USER = address(0xB0B);

    ERC20Mock internal asset;
    ERC20Mock internal secondAsset;
    ERC20Mock internal thirdAsset;
    MockBorrowToken internal token;
    BorrowerFlowHarness internal borrower;

    function setUp() public {
        asset = new ERC20Mock();
        secondAsset = new ERC20Mock();
        thirdAsset = new ERC20Mock();
        token = new MockBorrowToken();
        borrower = new BorrowerFlowHarness(address(this), address(token));

        token.setBorrower(address(borrower));
        token.mint(USER, COLLATERAL);

        asset.mint(address(token), ASSET_LIQUIDITY);
        secondAsset.mint(address(token), SECOND_ASSET_LIQUIDITY);

        token.setPrice(address(asset), ASSET_PRICE);
        token.setPrice(address(secondAsset), SECOND_ASSET_PRICE);
        token.setPrice(address(thirdAsset), 1e18);

        borrower.addBorrowableAsset(address(asset));
        borrower.addBorrowableAsset(address(secondAsset));

        vm.prank(USER);
        token.approve(address(borrower), type(uint256).max);

        vm.prank(USER);
        borrower.lock(COLLATERAL);
    }

    function _borrow(address assetAddress, uint256 amount) internal {
        vm.prank(USER);
        borrower.borrow(IBorrower.BorrowCall({asset: assetAddress, amount: amount}));
    }

    function _approveRepay(address assetAddress) internal {
        vm.prank(USER);
        IERC20(assetAddress).approve(address(borrower), type(uint256).max);
    }

    function test_constructorRevertsWhenControllerIsZero() public {
        vm.expectRevert(Borrower.Borrower__Misconfigured.selector);
        new Borrower(address(0), address(token));
    }

    function test_constructorRevertsWhenTokenIsZero() public {
        vm.expectRevert(Borrower.Borrower__Misconfigured.selector);
        new Borrower(address(this), address(0));
    }

    function test_addBorrowableAssetRevertsWhenCallerIsNotController() public {
        vm.prank(USER);
        vm.expectRevert(Borrower.Borrower__ControllerOnly.selector);
        borrower.addBorrowableAsset(address(thirdAsset));
    }

    function test_addBorrowableAssetRevertsWhenAssetIsZero() public {
        vm.expectRevert(Borrower.Borrower__AssetAddressZero.selector);
        borrower.addBorrowableAsset(address(0));
    }

    function test_addBorrowableAssetIgnoresDuplicateAsset() public {
        assertEq(borrower.borrowableAssets(0), address(asset));
        assertEq(borrower.borrowableAssets(1), address(secondAsset));

        borrower.addBorrowableAsset(address(asset));

        assertEq(borrower.borrowableAssets(0), address(asset));
        assertEq(borrower.borrowableAssets(1), address(secondAsset));
        vm.expectRevert();
        borrower.borrowableAssets(2);
    }

    function test_borrowTransfersAssetAndUpdatesDebt() public {
        _borrow(address(asset), 150e18);

        assertEq(asset.balanceOf(USER), 150e18);
        assertEq(borrower.borrowedOf(USER, address(asset)), 150e18);
        assertEq(borrower.totalBorrows(address(asset)), 150e18);
        assertEq(asset.balanceOf(address(token)), ASSET_LIQUIDITY - 150e18);
    }

    function test_borrowRevertsWhenBorrowAmountExceedsCapacity() public {
        vm.prank(USER);
        vm.expectRevert(Borrower.Borrower__ExceedsBorrowingCapacity.selector);
        borrower.borrow(IBorrower.BorrowCall({asset: address(asset), amount: 201e18}));

        assertEq(asset.balanceOf(USER), 0);
        assertEq(borrower.borrowedOf(USER, address(asset)), 0);
        assertEq(borrower.totalBorrows(address(asset)), 0);
    }

    function test_borrowRevertsWhenAssetIsNotBorrowable() public {
        vm.prank(USER);
        vm.expectRevert(Borrower.Borrower__AssetNotBorrowable.selector);
        borrower.borrow(IBorrower.BorrowCall({asset: address(thirdAsset), amount: 1e18}));
    }

    function test_borrowMultipleUsesOriginalCallerAcrossAllBorrows() public {
        IBorrower.BorrowCall[] memory calls = new IBorrower.BorrowCall[](2);
        calls[0] = IBorrower.BorrowCall({asset: address(asset), amount: 150e18});
        calls[1] = IBorrower.BorrowCall({asset: address(secondAsset), amount: 40e18});

        vm.prank(USER);
        borrower.borrowMultiple(calls);

        assertEq(asset.balanceOf(USER), 150e18);
        assertEq(secondAsset.balanceOf(USER), 40e18);
        assertEq(borrower.borrowedOf(USER, address(asset)), 150e18);
        assertEq(borrower.borrowedOf(USER, address(secondAsset)), 40e18);
        assertEq(borrower.borrowedOf(address(borrower), address(asset)), 0);
        assertEq(borrower.borrowedOf(address(borrower), address(secondAsset)), 0);
        assertEq(borrower.totalBorrows(address(asset)), 150e18);
        assertEq(borrower.totalBorrows(address(secondAsset)), 40e18);
    }

    function test_borrowMultipleRevertsAtomicallyWhenAnyBorrowFails() public {
        IBorrower.BorrowCall[] memory calls = new IBorrower.BorrowCall[](2);
        calls[0] = IBorrower.BorrowCall({asset: address(asset), amount: 150e18});
        calls[1] = IBorrower.BorrowCall({asset: address(secondAsset), amount: 60e18});

        vm.prank(USER);
        vm.expectRevert(Borrower.Borrower__ExceedsBorrowingCapacity.selector);
        borrower.borrowMultiple(calls);

        assertEq(asset.balanceOf(USER), 0);
        assertEq(secondAsset.balanceOf(USER), 0);
        assertEq(borrower.borrowedOf(USER, address(asset)), 0);
        assertEq(borrower.borrowedOf(USER, address(secondAsset)), 0);
        assertEq(borrower.totalBorrows(address(asset)), 0);
        assertEq(borrower.totalBorrows(address(secondAsset)), 0);
    }

    function test_repayTransfersAssetBackAndReducesDebt() public {
        _borrow(address(asset), 150e18);
        _approveRepay(address(asset));

        vm.prank(USER);
        borrower.repay(IBorrower.RepayCall({asset: address(asset), amount: 40e18}));

        assertEq(asset.balanceOf(USER), 110e18);
        assertEq(asset.balanceOf(address(token)), ASSET_LIQUIDITY - 110e18);
        assertEq(borrower.borrowedOf(USER, address(asset)), 110e18);
        assertEq(borrower.totalBorrows(address(asset)), 110e18);
    }

    function test_repayCapsAtOutstandingDebt() public {
        _borrow(address(asset), 150e18);
        _approveRepay(address(asset));

        vm.prank(USER);
        borrower.repay(IBorrower.RepayCall({asset: address(asset), amount: 200e18}));

        assertEq(asset.balanceOf(USER), 0);
        assertEq(asset.balanceOf(address(token)), ASSET_LIQUIDITY);
        assertEq(borrower.borrowedOf(USER, address(asset)), 0);
        assertEq(borrower.totalBorrows(address(asset)), 0);
    }

    function test_repayRevertsWhenAssetIsNotBorrowable() public {
        thirdAsset.mint(USER, 10e18);

        vm.prank(USER);
        thirdAsset.approve(address(borrower), type(uint256).max);

        vm.prank(USER);
        vm.expectRevert(Borrower.Borrower__AssetNotBorrowable.selector);
        borrower.repay(IBorrower.RepayCall({asset: address(thirdAsset), amount: 1e18}));
    }

    function test_repayMultipleRepaysAcrossAssets() public {
        _borrow(address(asset), 150e18);
        _borrow(address(secondAsset), 40e18);

        vm.startPrank(USER);
        asset.approve(address(borrower), type(uint256).max);
        secondAsset.approve(address(borrower), type(uint256).max);
        vm.stopPrank();

        IBorrower.RepayCall[] memory calls = new IBorrower.RepayCall[](2);
        calls[0] = IBorrower.RepayCall({asset: address(asset), amount: 50e18});
        calls[1] = IBorrower.RepayCall({asset: address(secondAsset), amount: 10e18});

        vm.prank(USER);
        borrower.repayMultiple(calls);

        assertEq(asset.balanceOf(USER), 100e18);
        assertEq(secondAsset.balanceOf(USER), 30e18);
        assertEq(borrower.borrowedOf(USER, address(asset)), 100e18);
        assertEq(borrower.borrowedOf(USER, address(secondAsset)), 30e18);
        assertEq(borrower.borrowedOf(address(borrower), address(asset)), 0);
        assertEq(borrower.borrowedOf(address(borrower), address(secondAsset)), 0);
        assertEq(borrower.totalBorrows(address(asset)), 100e18);
        assertEq(borrower.totalBorrows(address(secondAsset)), 30e18);
    }

    function test_repayMultipleRevertsAtomicallyWhenAnyRepayFails() public {
        _borrow(address(asset), 150e18);
        _borrow(address(secondAsset), 40e18);

        _approveRepay(address(asset));

        IBorrower.RepayCall[] memory calls = new IBorrower.RepayCall[](2);
        calls[0] = IBorrower.RepayCall({asset: address(asset), amount: 50e18});
        calls[1] = IBorrower.RepayCall({asset: address(secondAsset), amount: 10e18});

        vm.prank(USER);
        vm.expectRevert();
        borrower.repayMultiple(calls);

        assertEq(asset.balanceOf(USER), 150e18);
        assertEq(secondAsset.balanceOf(USER), 40e18);
        assertEq(borrower.borrowedOf(USER, address(asset)), 150e18);
        assertEq(borrower.borrowedOf(USER, address(secondAsset)), 40e18);
        assertEq(borrower.totalBorrows(address(asset)), 150e18);
        assertEq(borrower.totalBorrows(address(secondAsset)), 40e18);
    }
}
