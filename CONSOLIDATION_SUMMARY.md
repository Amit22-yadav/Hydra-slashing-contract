# Slashing Contract Consolidation Summary

## Overview

Consolidated the SlashingEscrow functionality into the Slashing contract to simplify the architecture. Now everything is handled by a single contract instead of two separate contracts.

## Changes Made

### 1. Unified Slashing.sol Contract

**Location**: `contracts/HydraStaking/modules/Slashing/Slashing.sol`

**Now includes**:
- Evidence validation and BLS signature verification
- 100% fixed penalty enforcement
- Mass slashing protection (rate limiting + tombstone cap)
- **NEW**: 30-day fund locking (previously in SlashingEscrow)
- **NEW**: Governance withdrawal commands (burn or send to treasury)
- Evidence storage for auditing

**Key additions from SlashingEscrow**:

```solidity
// Constants
uint256 public constant LOCK_PERIOD = 30 days;

// State variables
address public governance;
address public daoTreasury;
mapping(address => LockedFunds) public lockedFunds;

struct LockedFunds {
    uint256 amount;
    uint256 lockTimestamp;
    bool withdrawn;
}

// Governance functions
function lockFunds(address validator) external payable onlySystemCall;
function burnLockedFunds(address validator) external onlyGovernance;
function sendToTreasury(address validator) external onlyGovernance;
function batchBurnLockedFunds(address[] calldata validators) external onlyGovernance;
function batchSendToTreasury(address[] calldata validators) external onlyGovernance;
function setGovernance(address newGovernance) external onlyGovernance;
function setDaoTreasury(address newTreasury) external onlyGovernance;

// View functions
function isUnlocked(address validator) external view returns (bool);
function getUnlockTime(address validator) external view returns (uint256);
function getRemainingLockTime(address validator) external view returns (uint256);
```

**Updated initialize function**:
```solidity
function initialize(
    address hydraChainAddr,
    address governanceAddr,        // NEW: replaces slashingEscrowAddr
    address daoTreasuryAddr,       // NEW
    uint256 initialMaxSlashingsPerBlock
) external initializer onlySystemCall
```

### 2. Updated Inspector.sol Contract

**Location**: `contracts/HydraChain/modules/Inspector/Inspector.sol`

**Changes**:
- Removed `slashingEscrow` state variable
- Removed `setSlashingEscrow()` function
- Updated `slashValidator()` to call `ISlashingWithLock(slashingContract).lockFunds()` instead of forwarding to separate escrow
- Updated interface from `ISlashingEscrow` to `ISlashingWithLock`
- Updated error from `EscrowNotSet()` to `SlashingNotSet()`
- Updated comments to reference unified Slashing contract

**Key change in slashValidator()**:
```solidity
// OLD (two contracts):
ISlashingEscrow(slashingEscrow).lockFunds{value: penaltyAmount}(validator);

// NEW (single contract):
ISlashingWithLock(slashingContract).lockFunds{value: penaltyAmount}(validator);
```

### 3. Archived Files

**Moved to backup**:
- `SlashingEscrow.sol` → `SlashingEscrow_BACKUP.sol`

## Architecture Comparison

### Before (Two Contracts)

```
┌─────────────────────┐
│   Slashing.sol      │
│ - Evidence validate │
│ - BLS verification  │
│ - Rate limiting     │
└──────────┬──────────┘
           │ calls
           ▼
┌──────────────────────┐
│   Inspector.sol      │
│ - Execute slashing   │
│ - Ban validator      │
└──────────┬───────────┘
           │ forwards funds
           ▼
┌──────────────────────┐
│ SlashingEscrow.sol   │
│ - Lock funds 30 days │
│ - Governance control │
└──────────────────────┘
```

### After (Single Contract)

```
┌─────────────────────────────┐
│      Slashing.sol           │
│ - Evidence validate         │
│ - BLS verification          │
│ - Rate limiting             │
│ - Lock funds 30 days ◄─────┐│
│ - Governance control        ││
└──────────┬──────────────────┘│
           │ calls              │
           ▼                    │
┌──────────────────────┐       │
│   Inspector.sol      │       │
│ - Execute slashing   │       │
│ - Ban validator      │       │
│ - Forward to Slashing├───────┘
└──────────────────────┘
```

## Benefits of Consolidation

1. **Simpler Architecture**: One contract instead of two
2. **Reduced Gas Costs**: One less contract call in the slashing flow
3. **Easier Deployment**: Only need to deploy and configure one contract
4. **Clearer Ownership**: All slashing logic in one place
5. **Fewer Integration Points**: Inspector only needs to know about Slashing contract
6. **Single Source of Truth**: Evidence and locked funds in same contract

## Complete Slashing Flow (After Consolidation)

1. **Node-side**: Double signing detected → System transaction created
2. **Slashing.slashValidator()**: Validates evidence, verifies BLS signatures
3. **Inspector.slashValidator()**: Gets stake, calls `penalizeStaker()`, forwards funds
4. **Slashing.lockFunds()**: Locks funds with 30-day timestamp
5. **After 30 days**: Governance calls `burnLockedFunds()` or `sendToTreasury()`

## Governance Commands (Unchanged)

Same commands as before, just called on Slashing contract instead of SlashingEscrow:

### Single Validator Commands
```bash
# Burn slashed funds
cast send $SLASHING "burnLockedFunds(address)" $VALIDATOR --from $GOVERNANCE

# Send to treasury
cast send $SLASHING "sendToTreasury(address)" $VALIDATOR --from $GOVERNANCE
```

### Batch Commands (Mass Slashing)
```bash
# Batch burn
cast send $SLASHING "batchBurnLockedFunds(address[])" "[$VALIDATOR1,$VALIDATOR2,...]" --from $GOVERNANCE

# Batch send to treasury
cast send $SLASHING "batchSendToTreasury(address[])" "[$VALIDATOR1,$VALIDATOR2,...]" --from $GOVERNANCE
```

### Query Commands
```bash
# Check if unlocked
cast call $SLASHING "isUnlocked(address)(bool)" $VALIDATOR

# Get unlock time
cast call $SLASHING "getUnlockTime(address)(uint256)" $VALIDATOR

# Get remaining lock time
cast call $SLASHING "getRemainingLockTime(address)(uint256)" $VALIDATOR

# Get locked funds details
cast call $SLASHING "lockedFunds(address)(uint256,uint256,bool)" $VALIDATOR
```

## Deployment Changes

### Before (Two Contracts)
1. Deploy Slashing contract
2. Deploy SlashingEscrow contract
3. Initialize Slashing with escrow address
4. Initialize SlashingEscrow with governance/treasury
5. Configure Inspector with both addresses

### After (Single Contract)
1. Deploy Slashing contract
2. Initialize Slashing with governance/treasury
3. Configure Inspector with Slashing address

## Migration Notes

If upgrading from the two-contract version:

1. Deploy new unified Slashing contract
2. Initialize with governance and DAO treasury addresses
3. Update Inspector to point to new Slashing contract
4. Remove references to old SlashingEscrow contract
5. **Note**: Cannot migrate existing locked funds from old escrow automatically
   - Option A: Wait for existing locks to expire, then upgrade
   - Option B: Manual migration script to transfer locked funds

## Files Modified

1. ✅ `contracts/HydraStaking/modules/Slashing/Slashing.sol` - Added escrow logic
2. ✅ `contracts/HydraChain/modules/Inspector/Inspector.sol` - Updated to call unified contract
3. ✅ `contracts/HydraStaking/modules/Slashing/SlashingEscrow.sol` - Moved to backup

## Testing Checklist

- [ ] Test evidence validation with BLS signatures
- [ ] Test lockFunds() is called correctly from Inspector
- [ ] Test 30-day lock period enforcement
- [ ] Test governance commands (burn and sendToTreasury)
- [ ] Test batch operations for mass slashing
- [ ] Test view functions (isUnlocked, getUnlockTime, getRemainingLockTime)
- [ ] Test rate limiting still works (maxSlashingsPerBlock)
- [ ] Test tombstone cap still works (_hasBeenSlashed)
- [ ] Test governance transfer (setGovernance)
- [ ] Test treasury update (setDaoTreasury)

## Remaining Requirements ✅

All client requirements still met:
- ✅ 100% slash (fixed penalty - `PENALTY_PERCENTAGE = 10000`)
- ✅ 30-day lock (`LOCK_PERIOD = 30 days`)
- ✅ Governance withdrawal per-validator (burn or treasury)
- ✅ Mass slashing protection (rate limiting + tombstone)
- ✅ Evidence storage for auditing
- ✅ Reuse existing Inspector + penalizeStaker pattern
- ✅ Wait for epoch boundary (Option A approved by client)
