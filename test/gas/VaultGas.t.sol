///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {Kernel} from "../../src/Kernel.sol";
import {Slots} from "../../src/libraries/Slots.sol";
import {Vault} from "../../src/Vault.sol";

contract VaultReadHarness is Vault {
    constructor(address controller, address kernel) Vault(controller, kernel) {}

    function readAssetsOnly() external view returns (address[] memory) {
        return _readAssets();
    }

    function buildTreasurySlotsOnly() external view returns (bytes32[] memory slots) {
        address[] memory assets = _readAssets();
        slots = new bytes32[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            slots[i] = _treasuryAmountSlot(assets[i]);
        }
    }

    function readBackingAmountsOnly() external view returns (bytes32[] memory amounts) {
        address[] memory assets = _readAssets();
        bytes32[] memory slots = new bytes32[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            slots[i] = _backingAmountSlot(assets[i]);
        }
        amounts = KERNEL.viewData(slots);
    }

    function readTreasuryAmountsOnly() external view returns (bytes32[] memory amounts) {
        address[] memory assets = _readAssets();
        bytes32[] memory slots = new bytes32[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            slots[i] = _treasuryAmountSlot(assets[i]);
        }
        amounts = KERNEL.viewData(slots);
    }
}

contract VaultGasTest is Test {
    bytes32 internal constant TREASURY_AMOUNT_SLOT = Slots.TREASURY_AMOUNT_SLOT;
    bytes32 internal constant BACKING_AMOUNT_SLOT = Slots.BACKING_AMOUNT_SLOT;
    bytes32 internal constant ASSET_COUNT_SLOT = Slots.ASSETS_LENGTH_SLOT;
    bytes32 internal constant ASSET_BASE_SLOT = Slots.ASSETS_BASE_SLOT;

    Kernel internal kernel;
    VaultReadHarness internal vault;

    function setUp() public {
        kernel = new Kernel(address(this));
        vault = new VaultReadHarness(address(this), address(kernel));
    }

    function testGasBackingBalances1Asset() public {
        address[] memory assets = _makeAssets(1);
        _seedAssets(assets);
        _seedBackingBalances(assets, 100);

        IVault.AssetBalance[] memory balances = vault.backingBalances();

        assertEq(balances.length, 1);
        assertEq(balances[0].asset, assets[0]);
        assertEq(balances[0].amount, 100);
    }

    function testGasBackingBalances3Assets() public {
        address[] memory assets = _makeAssets(3);
        _seedAssets(assets);
        _seedBackingBalances(assets, 100);

        IVault.AssetBalance[] memory balances = vault.backingBalances();

        assertEq(balances.length, 3);
        _assertBalances(balances, assets, 100);
    }

    function testGasBackingBalances5Assets() public {
        address[] memory assets = _makeAssets(5);
        _seedAssets(assets);
        _seedBackingBalances(assets, 100);

        IVault.AssetBalance[] memory balances = vault.backingBalances();

        assertEq(balances.length, 5);
        _assertBalances(balances, assets, 100);
    }

    function testGasBackingBalances10Assets() public {
        address[] memory assets = _makeAssets(10);
        _seedAssets(assets);
        _seedBackingBalances(assets, 100);

        IVault.AssetBalance[] memory balances = vault.backingBalances();

        assertEq(balances.length, 10);
        _assertBalances(balances, assets, 100);
    }

    function testGasBackingBalances20Assets() public {
        address[] memory assets = _makeAssets(20);
        _seedAssets(assets);
        _seedBackingBalances(assets, 100);

        IVault.AssetBalance[] memory balances = vault.backingBalances();

        assertEq(balances.length, 20);
        _assertBalances(balances, assets, 100);
    }

    function testGasBackingBalances50Assets() public {
        address[] memory assets = _makeAssets(50);
        _seedAssets(assets);
        _seedBackingBalances(assets, 100);

        IVault.AssetBalance[] memory balances = vault.backingBalances();

        assertEq(balances.length, 50);
        _assertBalances(balances, assets, 100);
    }

    function testGasTreasuryBalances1Asset() public {
        address[] memory assets = _makeAssets(1);
        _seedAssets(assets);
        _seedTreasuryBalances(assets, 200);

        IVault.AssetBalance[] memory balances = vault.treasuryBalances();

        assertEq(balances.length, 1);
        assertEq(balances[0].asset, assets[0]);
        assertEq(balances[0].amount, 200);
    }

    function testGasTreasuryBalances3Assets() public {
        address[] memory assets = _makeAssets(3);
        _seedAssets(assets);
        _seedTreasuryBalances(assets, 200);

        IVault.AssetBalance[] memory balances = vault.treasuryBalances();

        assertEq(balances.length, 3);
        _assertBalances(balances, assets, 200);
    }

    function testGasTreasuryBalances5Assets() public {
        address[] memory assets = _makeAssets(5);
        _seedAssets(assets);
        _seedTreasuryBalances(assets, 200);

        IVault.AssetBalance[] memory balances = vault.treasuryBalances();

        assertEq(balances.length, 5);
        _assertBalances(balances, assets, 200);
    }

    function testGasTreasuryBalances10Assets() public {
        address[] memory assets = _makeAssets(10);
        _seedAssets(assets);
        _seedTreasuryBalances(assets, 200);

        IVault.AssetBalance[] memory balances = vault.treasuryBalances();

        assertEq(balances.length, 10);
        _assertBalances(balances, assets, 200);
    }

    function testGasTreasuryBalances20Assets() public {
        address[] memory assets = _makeAssets(20);
        _seedAssets(assets);
        _seedTreasuryBalances(assets, 200);

        IVault.AssetBalance[] memory balances = vault.treasuryBalances();

        assertEq(balances.length, 20);
        _assertBalances(balances, assets, 200);
    }

    function testGasTreasuryBalances50Assets() public {
        address[] memory assets = _makeAssets(50);
        _seedAssets(assets);
        _seedTreasuryBalances(assets, 200);

        IVault.AssetBalance[] memory balances = vault.treasuryBalances();

        assertEq(balances.length, 50);
        _assertBalances(balances, assets, 200);
    }

    function testGasReadAssetsOnly1Asset() public {
        address[] memory assets = _makeAssets(1);
        _seedAssets(assets);

        address[] memory readAssets = vault.readAssetsOnly();

        assertEq(readAssets.length, 1);
    }

    function testGasReadAssetsOnly10Assets() public {
        address[] memory assets = _makeAssets(10);
        _seedAssets(assets);

        address[] memory readAssets = vault.readAssetsOnly();

        assertEq(readAssets.length, 10);
    }

    function testGasReadAssetsOnly50Assets() public {
        address[] memory assets = _makeAssets(50);
        _seedAssets(assets);

        address[] memory readAssets = vault.readAssetsOnly();

        assertEq(readAssets.length, 50);
    }

    function testGasBuildTreasurySlotsOnly1Asset() public {
        address[] memory assets = _makeAssets(1);
        _seedAssets(assets);

        bytes32[] memory slots = vault.buildTreasurySlotsOnly();

        assertEq(slots.length, 1);
    }

    function testGasBuildTreasurySlotsOnly10Assets() public {
        address[] memory assets = _makeAssets(10);
        _seedAssets(assets);

        bytes32[] memory slots = vault.buildTreasurySlotsOnly();

        assertEq(slots.length, 10);
    }

    function testGasBuildTreasurySlotsOnly50Assets() public {
        address[] memory assets = _makeAssets(50);
        _seedAssets(assets);

        bytes32[] memory slots = vault.buildTreasurySlotsOnly();

        assertEq(slots.length, 50);
    }

    function testGasReadBackingAmountsOnly1Asset() public {
        address[] memory assets = _makeAssets(1);
        _seedAssets(assets);
        _seedBackingBalances(assets, 100);

        bytes32[] memory amounts = vault.readBackingAmountsOnly();

        assertEq(amounts.length, 1);
        assertEq(amounts[0], bytes32(uint256(100)));
    }

    function testGasReadBackingAmountsOnly10Assets() public {
        address[] memory assets = _makeAssets(10);
        _seedAssets(assets);
        _seedBackingBalances(assets, 100);

        bytes32[] memory amounts = vault.readBackingAmountsOnly();

        assertEq(amounts.length, 10);
        assertEq(amounts[0], bytes32(uint256(100)));
    }

    function testGasReadBackingAmountsOnly50Assets() public {
        address[] memory assets = _makeAssets(50);
        _seedAssets(assets);
        _seedBackingBalances(assets, 100);

        bytes32[] memory amounts = vault.readBackingAmountsOnly();

        assertEq(amounts.length, 50);
        assertEq(amounts[0], bytes32(uint256(100)));
    }

    function testGasReadTreasuryAmountsOnly1Asset() public {
        address[] memory assets = _makeAssets(1);
        _seedAssets(assets);
        _seedTreasuryBalances(assets, 200);

        bytes32[] memory amounts = vault.readTreasuryAmountsOnly();

        assertEq(amounts.length, 1);
        assertEq(amounts[0], bytes32(uint256(200)));
    }

    function testGasReadTreasuryAmountsOnly10Assets() public {
        address[] memory assets = _makeAssets(10);
        _seedAssets(assets);
        _seedTreasuryBalances(assets, 200);

        bytes32[] memory amounts = vault.readTreasuryAmountsOnly();

        assertEq(amounts.length, 10);
        assertEq(amounts[0], bytes32(uint256(200)));
    }

    function testGasReadTreasuryAmountsOnly50Assets() public {
        address[] memory assets = _makeAssets(50);
        _seedAssets(assets);
        _seedTreasuryBalances(assets, 200);

        bytes32[] memory amounts = vault.readTreasuryAmountsOnly();

        assertEq(amounts.length, 50);
        assertEq(amounts[0], bytes32(uint256(200)));
    }

    function _makeAssets(uint256 count) internal pure returns (address[] memory assets) {
        assets = new address[](count);
        uint160 asset = 0xA1;
        for (uint256 i = 0; i < count;) {
            assets[i] = address(asset);
            unchecked {
                ++i;
                ++asset;
            }
        }
    }

    function _assertBalances(IVault.AssetBalance[] memory balances, address[] memory assets, uint256 startAmount)
        internal
        pure
    {
        for (uint256 i = 0; i < assets.length; i++) {
            assertEq(balances[i].asset, assets[i]);
            assertEq(balances[i].amount, startAmount + i);
        }
    }

    function _seedAssets(address[] memory assets) internal {
        kernel.updateState(ASSET_COUNT_SLOT, bytes32(assets.length));

        for (uint256 i = 0; i < assets.length; i++) {
            kernel.updateState(_slotOffset(ASSET_BASE_SLOT, i), bytes32(uint256(uint160(assets[i]))));
        }
    }

    function _seedBackingBalances(address[] memory assets, uint256 startAmount) internal {
        for (uint256 i = 0; i < assets.length; i++) {
            kernel.updateState(_amountSlot(BACKING_AMOUNT_SLOT, assets[i]), bytes32(startAmount + i));
        }
    }

    function _seedTreasuryBalances(address[] memory assets, uint256 startAmount) internal {
        for (uint256 i = 0; i < assets.length; i++) {
            kernel.updateState(_amountSlot(TREASURY_AMOUNT_SLOT, assets[i]), bytes32(startAmount + i));
        }
    }

    function _amountSlot(bytes32 namespace, address asset) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, namespace)
            mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            slot := keccak256(0x00, 0x40)
        }
    }

    function _slotOffset(bytes32 slot, uint256 offset) internal pure returns (bytes32) {
        return bytes32(uint256(slot) + offset);
    }
}
