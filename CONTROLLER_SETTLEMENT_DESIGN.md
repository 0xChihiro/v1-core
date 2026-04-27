# Controller Settlement Design Sketch

This began as a design-only sketch for turning `Controller` into the protocol clearing house.
The current implementation now lives in `src/Controller.sol`; this file remains an audit note for the settlement model.

## Goal

The controller should stop having one clearing function per product:

```solidity
clearAuction(...)
clearBorrow(...)
clearRepay(...)
clearMarketBuy(...)
clearMarketSell(...)
```

Instead, modules should submit settlement intents and the controller should apply them only if shared protocol invariants hold.

The intended boundary is:

```text
Module     = decides what happened and requested allocation
Controller = calculates required fees, applies approved kernel updates, mints tokens, and validates invariants
Vault      = moves assets
Kernel     = records accounting state
```

The first implementation should support non-redemption inflow settlements. This is enough to replace the current `clearAuction` path and can also support future market-maker buys where user assets enter the protocol, protocol fees are paid, net value is credited into backing/team/treasury buckets, connected ERC20 tokens are minted, and product-specific kernel state is updated.

Redemptions, borrows, and other flows that intentionally reduce backing should be added later as explicit settlement modes with supply/debt-aware invariants.

## Important Slot Note

`Vault`, `Controller`, and the tests now use the canonical bucket and asset-list constants from `src/libraries/Slots.sol`.
The controller can verify backing invariants because bucket slot derivation is shared across the system.

## Stage 1 Settlement Model

Stage 1 should be intentionally narrow:

- all external receipts, when present, enter the `Treasury` bucket first;
- the controller calculates the auction fee automatically when tokens are minted;
- protocol fees are paid from `Treasury` to `PROTOCOL_COLLECTOR`;
- credits can move value from `Treasury` to `Backing` or `Team`;
- approved kernel state updates can be applied for product accounting;
- optional mint instructions mint the connected ERC20 from the controller;
- whatever remains in `Treasury` is retained treasury value;
- no arbitrary external payments;
- no direct state updates to protected vault accounting namespaces;
- no backing decreases;
- minting must not push the connected ERC20 above max supply.

This replaces `clearAuction` without making `settle` a privileged multicall.

## Connected Token

The connected ERC20 should stay simple. Modules should not receive mint authority directly.

```solidity
interface IEntenToken {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}
```

The controller owns mint authority on the token:

```solidity
IEntenToken public immutable TOKEN;
```

For Stage 1, minting is allowed only through `settle`. A module can request mints, but the controller performs them atomically after receiving assets, paying the auction fee, crediting buckets, and applying approved kernel state updates.

The controller does not decide auction pricing or market-maker curve output. The module tells the controller how many tokens to mint. The controller only enforces the protocol-level cap:

```text
total supply after mint <= max supply
```

The max supply can be read from `Slots.MAX_SUPPLY_SLOT` in the kernel. This keeps minting simple: modules calculate issuance, while the controller ensures no module can mint beyond the connected token's configured maximum supply.

## Auction Fee

There is no liquidity fee in this model. Teams that use the liquidity path should not pay a protocol liquidity fee.

The only protocol fee in Stage 1 is the auction fee. The controller applies it automatically whenever a settlement mints tokens:

```solidity
function _feeBps(Settlement calldata settlement) internal pure returns (uint256) {
    if (settlement.mints.length == 0) return 0;
    return AUCTION_FEE_BPS;
}
```

The controller computes each protocol fee as:

```solidity
uint256 protocolFee = _mulDivUp(receipt.amount, _feeBps(settlement), BPS);
```

Modules should never pass protocol fee amounts or fee modes to the controller.

## Kernel State Updates

Future modules like borrow, repay, staking, vesting, launch scheduling, and market-maker configuration need to update protocol state that is not represented by vault bucket movements. The controller should support this through settlement, but it should not become an unrestricted storage writer.

Add state updates as explicit settlement instructions:

```solidity
enum StateOp {
    Set,
    Add,
    Sub
}

enum SlotDerivation {
    Direct,
    MappingKey,
    Offset
}

struct StateUpdate {
    bytes32 namespace;
    SlotDerivation derivation;
    bytes32 key;
    StateOp op;
    bytes32 data;
}
```

The controller derives the actual kernel slot from the namespace and key:

```solidity
function _deriveStateSlot(StateUpdate calldata update) internal pure returns (bytes32 slot) {
    if (update.derivation == SlotDerivation.Direct) {
        if (update.key != bytes32(0)) revert Controller__InvalidStateUpdate();
        return update.namespace;
    }

    if (update.derivation == SlotDerivation.MappingKey) {
        return _mappedSlot(update.namespace, update.key);
    }

    if (update.derivation == SlotDerivation.Offset) {
        return bytes32(uint256(update.namespace) + uint256(update.key));
    }

    revert Controller__InvalidStateUpdate();
}

function _mappedSlot(bytes32 namespace, bytes32 key) internal pure returns (bytes32 slot) {
    assembly ("memory-safe") {
        mstore(0x00, namespace)
        mstore(0x20, key)
        slot := keccak256(0x00, 0x40)
    }
}
```

This avoids accepting arbitrary raw `bytes32 slot` writes from modules. The final implementation should standardize module slot derivation around these helpers.

The controller applies state updates through `Kernel`:

```text
StateOp.Set -> KERNEL.updateState(slot, data)
StateOp.Add -> KERNEL.add(slot, data)
StateOp.Sub -> KERNEL.sub(slot, data)
```

State updates need their own permission layer:

```solidity
mapping(Keycode module => mapping(bytes32 namespace => bool allowed)) public statePermissions;
```

Suggested admin surface:

```solidity
event StatePermissionUpdated(Keycode indexed module, bytes32 indexed namespace, bool allowed);

error Controller__StatePermissionDenied(bytes32 namespace);
error Controller__InvalidStateUpdate();

function setStatePermission(
    Keycode module,
    bytes32 namespace,
    bool allowed
) external onlyRole(EXECUTOR_ROLE) {
    if (moduleForKeycode[module] == address(0)) revert Controller__ModuleNotInstalled(module);
    if (!activeModules[module]) revert Controller__ModuleNotActive(module);
    if (namespace == bytes32(0)) revert Controller__InvalidStateUpdate();
    if (_isProtectedAccountingNamespace(namespace)) revert Controller__StatePermissionDenied(namespace);

    statePermissions[module][namespace] = allowed;

    emit StatePermissionUpdated(module, namespace, allowed);
}
```

The controller must reject state updates to protected vault accounting namespaces:

```text
Slots.BACKING_AMOUNT_SLOT
Slots.TREASURY_AMOUNT_SLOT
Slots.TEAM_AMOUNT_SLOT
```

Those balances should only change through `VAULT.receiveAssets`, `VAULT.transferTreasuryAssets`, and `VAULT.credits`.

Borrow modules can use `stateUpdates` for debt and position accounting, but state permission only answers "may this module touch this namespace." Borrow health, collateralization, liquidation safety, and debt invariants still need a borrow-specific settlement rule later.

## Proposed Types

```solidity
struct Settlement {
    address payer;
    Receipt[] receipts;
    Credit[] credits;
    Mint[] mints;
    StateUpdate[] stateUpdates;
}

struct Receipt {
    address asset;
    uint256 amount;
}

struct Credit {
    address asset;
    IVault.Bucket to;
    uint256 amount;
}

struct Mint {
    address to;
    uint256 amount;
}
```

Treasury retained value is implicit:

```text
treasury retained = receipt amount - controller-calculated protocol fee - backing credits - team credits
```

## Mint Permissions

Because there is only one `settle` selector, modules need capability permissions rather than selector permissions. Minting should be explicitly granted:

```solidity
mapping(Keycode module => bool allowed) public mintPermissions;
```

Admin surface:

```solidity
event MintPermissionUpdated(Keycode indexed module, bool allowed);

error Controller__MintPermissionDenied(Keycode module);

function setMintPermission(Keycode module, bool allowed) external onlyRole(EXECUTOR_ROLE) {
    if (moduleForKeycode[module] == address(0)) revert Controller__ModuleNotInstalled(module);
    if (!activeModules[module]) revert Controller__ModuleNotActive(module);

    mintPermissions[module] = allowed;

    emit MintPermissionUpdated(module, allowed);
}
```

Examples:

```text
Auction module      -> mint permission enabled
MarketMaker module  -> mint permission enabled if it issues tokens
Liquidity module    -> no mint permission if it only seeds liquidity
Borrow/repay module -> no mint permission
```

The old `modulePermissions[Controller.settle.selector][module]` check becomes unnecessary if `settle` is the only module entrypoint. Active modules can call `settle`, while minting and state updates are guarded by capability permissions.

## Proposed `settle` Sketch

```solidity
event SettlementCleared(
    Keycode indexed module,
    address indexed payer,
    uint256 feeBps,
    uint256 receiptCount,
    uint256 creditCount,
    uint256 mintCount,
    uint256 stateUpdateCount
);

error Controller__InvalidSettlement();
error Controller__InvalidSettlementAsset();
error Controller__InvalidSettlementBucket();
error Controller__InvalidMint();
error Controller__MintExceedsMaxSupply(uint256 supplyAfter, uint256 maxSupply);
error Controller__SettlementOverAllocated(address asset);
error Controller__BackingInvariantBreach(address asset, uint256 beforeAmount, uint256 afterAmount);

function settle(Settlement calldata settlement) external onlyActiveModule {
    Keycode moduleKeycode = keycodeForModule[msg.sender];

    uint256 feeBps = _feeBps(settlement);

    _validateSettlementShape(settlement);
    _validateReceipts(settlement.receipts);
    _validateCredits(settlement);
    _validateMints(moduleKeycode, settlement);
    _validateStateUpdates(moduleKeycode, settlement.stateUpdates);
    _validatePerAssetAllocation(settlement, feeBps);

    address[] memory backingAssets = _collectBackingCreditAssets(settlement.credits);
    uint256[] memory backingBefore = _readBackingAmounts(backingAssets);
    uint256 supplyBefore = TOKEN.totalSupply();

    IVault.ReceiveCall[] memory receiveCalls = _buildReceiveCalls(settlement.payer, settlement.receipts);
    IVault.TreasuryCall[] memory protocolCalls = _buildProtocolFeeCalls(settlement.receipts, feeBps);
    IVault.CreditCall[] memory creditCalls = _buildCreditCalls(settlement.credits);

    if (receiveCalls.length != 0) {
        VAULT.receiveAssets(receiveCalls);
    }

    if (protocolCalls.length != 0) {
        VAULT.transferTreasuryAssets(protocolCalls);
    }

    if (creditCalls.length != 0) {
        VAULT.credits(creditCalls);
    }

    if (settlement.stateUpdates.length != 0) {
        _applyStateUpdates(settlement.stateUpdates);
    }

    if (settlement.mints.length != 0) {
        _mintTokens(settlement.mints);
    }

    _assertBackingNonDecreasing(backingAssets, backingBefore);
    _assertMintSupplyInvariant(supplyBefore, settlement.mints);

    emit SettlementCleared(
        moduleKeycode,
        settlement.payer,
        feeBps,
        settlement.receipts.length,
        settlement.credits.length,
        settlement.mints.length,
        settlement.stateUpdates.length
    );
}
```

## Validation Sketch

```solidity
function _validateSettlementShape(Settlement calldata settlement) internal pure {
    bool hasReceipts = settlement.receipts.length != 0;
    bool hasCredits = settlement.credits.length != 0;
    bool hasMints = settlement.mints.length != 0;
    bool hasStateUpdates = settlement.stateUpdates.length != 0;

    if (!hasReceipts && !hasCredits && !hasMints && !hasStateUpdates) {
        revert Controller__InvalidSettlement();
    }

    if (hasReceipts && settlement.payer == address(0)) revert Controller__ZeroAddress();

    if (!hasReceipts) {
        if (hasCredits || hasMints) revert Controller__InvalidSettlement();
    }
}

function _validateReceipts(Receipt[] calldata receipts) internal pure {
    for (uint256 i; i < receipts.length;) {
        if (receipts[i].asset == address(0) || receipts[i].amount == 0) {
            revert Controller__InvalidSettlementAsset();
        }

        for (uint256 j = i + 1; j < receipts.length;) {
            if (receipts[i].asset == receipts[j].asset) revert Controller__InvalidSettlement();
            unchecked {
                ++j;
            }
        }

        unchecked {
            ++i;
        }
    }
}

function _validateCredits(Settlement calldata settlement) internal pure {
    for (uint256 i; i < settlement.credits.length;) {
        Credit calldata credit = settlement.credits[i];
        if (credit.asset == address(0) || credit.amount == 0) revert Controller__InvalidSettlementAsset();
        if (!_hasReceiptForAsset(settlement.receipts, credit.asset)) revert Controller__InvalidSettlement();

        // Stage 1 only allows Treasury -> Backing or Treasury -> Team.
        if (credit.to != IVault.Bucket.Backing && credit.to != IVault.Bucket.Team) {
            revert Controller__InvalidSettlementBucket();
        }

        unchecked {
            ++i;
        }
    }
}

function _validateMints(Keycode moduleKeycode, Settlement calldata settlement) internal view {
    if (settlement.mints.length != 0 && !mintPermissions[moduleKeycode]) {
        revert Controller__MintPermissionDenied(moduleKeycode);
    }

    for (uint256 i; i < settlement.mints.length;) {
        Mint calldata mint = settlement.mints[i];
        if (mint.to == address(0) || mint.amount == 0) revert Controller__InvalidMint();

        unchecked {
            ++i;
        }
    }
}

function _validateStateUpdates(Keycode moduleKeycode, StateUpdate[] calldata updates) internal view {
    for (uint256 i; i < updates.length;) {
        StateUpdate calldata update = updates[i];
        if (update.namespace == bytes32(0)) revert Controller__InvalidStateUpdate();
        if (!_isValidStateOp(update.op)) revert Controller__InvalidStateUpdate();
        if (_isProtectedAccountingNamespace(update.namespace)) {
            revert Controller__StatePermissionDenied(update.namespace);
        }
        if (!statePermissions[moduleKeycode][update.namespace]) {
            revert Controller__StatePermissionDenied(update.namespace);
        }

        _deriveStateSlot(update);

        unchecked {
            ++i;
        }
    }
}

function _isValidStateOp(StateOp op) internal pure returns (bool) {
    return op == StateOp.Set || op == StateOp.Add || op == StateOp.Sub;
}

function _validatePerAssetAllocation(Settlement calldata settlement, uint256 feeBps) internal pure {
    for (uint256 i; i < settlement.receipts.length;) {
        Receipt calldata receipt = settlement.receipts[i];

        uint256 protocolFee = _mulDivUp(receipt.amount, feeBps, BPS);
        uint256 credited = _sumCredits(settlement.credits, receipt.asset);

        if (protocolFee + credited > receipt.amount) {
            revert Controller__SettlementOverAllocated(receipt.asset);
        }

        unchecked {
            ++i;
        }
    }
}
```

## Call Builders

```solidity
function _buildReceiveCalls(
    address payer,
    Receipt[] calldata receipts
) internal pure returns (IVault.ReceiveCall[] memory calls) {
    calls = new IVault.ReceiveCall[](receipts.length);
    for (uint256 i; i < receipts.length;) {
        calls[i] = IVault.ReceiveCall({
            from: payer,
            asset: receipts[i].asset,
            amount: receipts[i].amount,
            bucket: IVault.Bucket.Treasury
        });
        unchecked {
            ++i;
        }
    }
}

function _buildProtocolFeeCalls(
    Receipt[] calldata receipts,
    uint256 feeBps
) internal view returns (IVault.TreasuryCall[] memory calls) {
    if (feeBps == 0) return new IVault.TreasuryCall[](0);

    calls = new IVault.TreasuryCall[](receipts.length);
    for (uint256 i; i < receipts.length;) {
        uint256 protocolFee = _mulDivUp(receipts[i].amount, feeBps, BPS);
        calls[i] = IVault.TreasuryCall({
            asset: receipts[i].asset,
            to: PROTOCOL_COLLECTOR,
            amount: protocolFee
        });
        unchecked {
            ++i;
        }
    }
}

function _buildCreditCalls(Credit[] calldata credits) internal pure returns (IVault.CreditCall[] memory calls) {
    calls = new IVault.CreditCall[](credits.length);
    for (uint256 i; i < credits.length;) {
        calls[i] = IVault.CreditCall({
            from: IVault.Bucket.Treasury,
            to: credits[i].to,
            asset: credits[i].asset,
            amount: credits[i].amount
        });
        unchecked {
            ++i;
        }
    }
}
```

## State And Token Application

```solidity
function _applyStateUpdates(StateUpdate[] calldata updates) internal {
    for (uint256 i; i < updates.length;) {
        StateUpdate calldata update = updates[i];
        bytes32 slot = _deriveStateSlot(update);

        if (update.op == StateOp.Set) {
            KERNEL.updateState(slot, update.data);
        } else if (update.op == StateOp.Add) {
            KERNEL.add(slot, update.data);
        } else if (update.op == StateOp.Sub) {
            KERNEL.sub(slot, update.data);
        } else {
            revert Controller__InvalidStateUpdate();
        }

        unchecked {
            ++i;
        }
    }
}

function _mintTokens(Mint[] calldata mints) internal {
    for (uint256 i; i < mints.length;) {
        TOKEN.mint(mints[i].to, mints[i].amount);
        unchecked {
            ++i;
        }
    }
}
```

## Helper Sketches

```solidity
function _hasReceiptForAsset(Receipt[] calldata receipts, address asset) internal pure returns (bool) {
    for (uint256 i; i < receipts.length;) {
        if (receipts[i].asset == asset) return true;
        unchecked {
            ++i;
        }
    }
    return false;
}

function _sumCredits(Credit[] calldata credits, address asset) internal pure returns (uint256 total) {
    for (uint256 i; i < credits.length;) {
        if (credits[i].asset == asset) total += credits[i].amount;
        unchecked {
            ++i;
        }
    }
}

function _collectBackingCreditAssets(Credit[] calldata credits) internal pure returns (address[] memory assets) {
    uint256 count;
    for (uint256 i; i < credits.length;) {
        if (credits[i].to == IVault.Bucket.Backing) ++count;
        unchecked {
            ++i;
        }
    }

    assets = new address[](count);
    uint256 cursor;
    for (uint256 i; i < credits.length;) {
        if (credits[i].to == IVault.Bucket.Backing) {
            assets[cursor] = credits[i].asset;
            unchecked {
                ++cursor;
            }
        }
        unchecked {
            ++i;
        }
    }
}

function _readBackingAmounts(address[] memory assets) internal view returns (uint256[] memory amounts) {
    amounts = new uint256[](assets.length);
    for (uint256 i; i < assets.length;) {
        amounts[i] = uint256(KERNEL.viewData(_amountSlot(IVault.Bucket.Backing, assets[i])));
        unchecked {
            ++i;
        }
    }
}

function _assertBackingNonDecreasing(address[] memory assets, uint256[] memory beforeAmounts) internal view {
    for (uint256 i; i < assets.length;) {
        uint256 afterAmount = uint256(KERNEL.viewData(_amountSlot(IVault.Bucket.Backing, assets[i])));
        if (afterAmount < beforeAmounts[i]) {
            revert Controller__BackingInvariantBreach(assets[i], beforeAmounts[i], afterAmount);
        }
        unchecked {
            ++i;
        }
    }
}

function _assertMintSupplyInvariant(uint256 supplyBefore, Mint[] calldata mints) internal view {
    uint256 minted;
    for (uint256 i; i < mints.length;) {
        minted += mints[i].amount;
        unchecked {
            ++i;
        }
    }

    uint256 supplyAfter = TOKEN.totalSupply();
    if (supplyAfter != supplyBefore + minted) revert Controller__InvalidMint();

    if (minted != 0) {
        uint256 maxSupply = uint256(KERNEL.viewData(Slots.MAX_SUPPLY_SLOT));
        if (supplyAfter > maxSupply) revert Controller__MintExceedsMaxSupply(supplyAfter, maxSupply);
    }
}

function _amountSlot(IVault.Bucket bucket, address asset) internal pure returns (bytes32 slot) {
    bytes32 namespace = _namespace(bucket);
    assembly ("memory-safe") {
        mstore(0x00, namespace)
        mstore(0x20, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
        slot := keccak256(0x00, 0x40)
    }
}

function _namespace(IVault.Bucket bucket) internal pure returns (bytes32 namespace) {
    if (bucket == IVault.Bucket.Backing) return Slots.BACKING_AMOUNT_SLOT;
    if (bucket == IVault.Bucket.Treasury) return Slots.TREASURY_AMOUNT_SLOT;
    if (bucket == IVault.Bucket.Team) return Slots.TEAM_AMOUNT_SLOT;
    revert Controller__InvalidSettlementBucket();
}

function _isProtectedAccountingNamespace(bytes32 namespace) internal pure returns (bool) {
    return namespace == Slots.BACKING_AMOUNT_SLOT
        || namespace == Slots.TREASURY_AMOUNT_SLOT
        || namespace == Slots.TEAM_AMOUNT_SLOT;
}
```

## Example: Current Auction Settlement

The current `clearAuction` example:

```text
gross:    1,000
fee:         25, calculated because the settlement mints tokens
backing:    300
team:       200
treasury:   475, implicit remainder
minted:     100, requested by auction module
```

Becomes:

```solidity
Settlement({
    payer: auctionWinner,
    receipts: [
        Receipt({asset: asset, amount: 1_000e18})
    ],
    credits: [
        Credit({asset: asset, to: IVault.Bucket.Backing, amount: 300e18}),
        Credit({asset: asset, to: IVault.Bucket.Team, amount: 200e18})
    ],
    mints: [
        Mint({to: auctionWinner, amount: 100e18})
    ],
    stateUpdates: []
});
```

The controller calculates:

```text
protocol fee = ceil(1,000 * AUCTION_FEE_BPS / BPS)
             = 25

treasury retained = receipt - protocol fee - backing credit - team credit
                  = 1,000 - 25 - 300 - 200
                  = 475

minted = 100
total supply after mint must be <= max supply
```

## Example: Fee-Free Liquidity Settlement

A fee-free settlement has no mints:

```solidity
Settlement({
    payer: team,
    receipts: [
        Receipt({asset: asset, amount: 100e18})
    ],
    credits: [
        Credit({asset: asset, to: IVault.Bucket.Backing, amount: 70e18}),
        Credit({asset: asset, to: IVault.Bucket.Team, amount: 5e18})
    ],
    mints: [],
    stateUpdates: []
});
```

The controller calculates:

```text
protocol fee = 0
treasury retained = 100 - 70 - 5 = 25
minted = 0
```

## Example: Borrow State Update

A future borrow module can submit state updates alongside asset movement once borrow-specific settlement rules exist:

```solidity
stateUpdates: [
    StateUpdate({
        namespace: Slots.USER_POSITION_BASE_SLOT,
        derivation: SlotDerivation.MappingKey,
        key: bytes32(uint256(uint160(user))),
        op: StateOp.Set,
        data: bytes32(newPositionValue)
    }),
    StateUpdate({
        namespace: Slots.ASSET_TOTAL_BORROWED_BASE_SLOT,
        derivation: SlotDerivation.MappingKey,
        key: bytes32(uint256(uint160(asset))),
        op: StateOp.Add,
        data: bytes32(borrowAmount)
    })
]
```

This is only namespace-authorized state mutation. It does not by itself prove the borrow is safe.

## Why This Is Safer Than Generic Calls

This design does not allow modules to submit arbitrary `(target, calldata)` calls.

Modules only submit accounting intentions:

- receive asset;
- credit treasury value into backing/team;
- update approved kernel namespaces;
- mint the connected ERC20;
- leave residual value in treasury.

The controller adds the auction fee whenever the settlement mints tokens. Liquidity settlements that do not mint tokens pay no protocol fee.

## Stage 2: Redemptions And Borrows

Redemptions and borrows should not be added by simply allowing arbitrary payments from `Backing`.

For redemptions, absolute backing can go down because token supply also goes down. The invariant should become supply-adjusted:

```text
backing value after / token supply after >= backing value before / token supply before
```

That requires additional primitives:

```solidity
struct Burn {
    address from;
    uint256 amount;
}

struct Payment {
    address asset;
    IVault.Bucket from;
    address to;
    uint256 amount;
}
```

It also requires a valuation layer for multi-asset backing. Without that, the controller can only enforce per-asset non-decrease, which is too strict for redemptions and too weak for cross-asset substitutions.

For borrows, the invariant should be debt/collateral-aware rather than just backing-aware:

```text
new debt is recorded
collateral is sufficient
borrowed backing is tracked
liquidation path exists
```

Borrow and repay modules would use `stateUpdates` for position/debt accounting, but those updates should be paired with borrow-specific invariant checks. `StateUpdate` permission only answers "may this module touch this namespace"; it does not prove the borrow is healthy.

Those should be separate settlement rules, not separate controller clearing functions.

## Migration Path

1. Reconcile bucket slot constants.
2. Add connected token storage and ensure the controller owns token mint authority.
3. Standardize state slot derivation helpers.
4. Add settlement structs, mint permissions, state permissions, mint validation, and `settle`.
5. Give minting modules mint permission.
6. Rewrite the auction module to submit receipts and credits only.
7. Remove caller-supplied protocol fee amounts from auction settlement data.
8. Add market-maker mints through `Settlement.mints` once the curve can provide mint amounts.
9. Add product state updates through `Settlement.stateUpdates` only after namespace derivation is standardized.
10. Remove `clearAuction` after tests cover equivalent behavior.
11. Add stage 2 settlement rules only when token supply, redemption, oracle, and debt invariants are ready.
