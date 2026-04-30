///SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

///@title Slots
///@notice Constant slots that are used throughout the base enten system
/// for specific storage spaces in the kernel

library Slots {
    // Vault Slots
    bytes32 internal constant TREASURY_AMOUNT_SLOT = keccak256("enten.vault.treasury.amount");
    bytes32 internal constant BACKING_AMOUNT_SLOT = keccak256("enten.vault.backing.amount");
    bytes32 internal constant TEAM_AMOUNT_SLOT = keccak256("enten.vault.team.amount");

    // Token Slots
    bytes32 internal constant MAX_SUPPLY_SLOT = keccak256("enten.token.max.supply");
    bytes32 internal constant BACKING_PERCENTAGE_SLOT = keccak256("enten.token.backing.percentage");
    bytes32 internal constant TEAM_PERCENTAGE_SLOT = keccak256("enten.token.team.percentage");
    bytes32 internal constant TREASURY_PERCENTAGE_SLOT = keccak256("enten.token.treasury.percentage");
    bytes32 internal constant ASSETS_LENGTH_SLOT = keccak256("enten.token.assets.length");
    bytes32 internal constant ASSETS_BASE_SLOT = keccak256("enten.token.assets");

    // Borrow Slots
    bytes32 internal constant USER_POSITION_BASE_SLOT = keccak256("enten.borrow.user.position");
    bytes32 internal constant ASSET_TOTAL_BORROWED_BASE_SLOT = keccak256("enten.borrow.asset.borrowed");
    bytes32 internal constant TOTAL_COLLATERL_SLOT = keccak256("enten.borrow.total.collateral");

    // Auction Slots
    bytes32 internal constant LOT_SIZE_SLOT = keccak256("enten.auction.lot.size");
    bytes32 internal constant MAX_SCALAR_SLOT = keccak256("enten.auction.max.scalar");
    bytes32 internal constant MIN_SCALAR_SLOT = keccak256("enten.auction.min.scalar");
    bytes32 internal constant EPOCH_LENGTH_SLOT = keccak256("enten.auction.epoch.length");
    bytes32 internal constant EPOCH_ID_SLOT = keccak256("enten.aucion.epoch.id");

    // Curve Slots
}
