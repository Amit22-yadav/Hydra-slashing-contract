# Slashing V3 Architecture - Final Implementation

## Overview

This document describes the final slashing architecture that implements all client requirements:
- ✅ **100% slash** for double signing (fixed penalty)
- ✅ **30-day lock** on slashed funds
- ✅ **Governance decision** per validator: burn OR send to DAO treasury
- ✅ **Mass slashing protection** (configurable max slashings per block)
- ✅ **Evidence storage** for auditing
- ✅ **Reuses existing Inspector + penalizeStaker pattern**

## Architecture Components

### 1. **Slashing.sol** (Evidence Validation Layer)
**Location**: `contracts/HydraStaking/modules/Slashing/Slashing_V3.sol`

**Responsibilities**:
- Validate cryptographic evidence (BLS signatures, message structure)
- Prevent double slashing (one validator can only be slashed once)
- Mass slashing protection (configurable max slashings per block)
- Store evidence hash for auditing
- Delegate execution to Inspector contract

**Key Features**:
```solidity
// Fixed 100% penalty
uint256 public constant PENALTY_PERCENTAGE = 10000; // 100% in basis points

// Mass slashing protection
uint256 public maxSlashingsPerBlock;
mapping(uint256 => uint256) public slashingsInBlock;

// Prevent double slashing
mapping(address => bool) private _hasBeenSlashed;

// Evidence storage
mapping(address => bytes32) public slashingEvidenceHash;
```

**Main Function**:
```solidity
function slashValidator(
    address validator,
    IBFTMessage calldata msg1,
    IBFTMessage calldata msg2,
    string calldata reason
) external onlySystemCall
```

**Flow**:
1. Validate evidence structure (same height, round, type; different data)
2. Verify BLS signatures on both messages
3. Check mass slashing limit not exceeded
4. Store evidence hash
5. Mark validator as slashed
6. Call `Inspector.slashValidator(validator, reason)`

---

### 2. **Inspector_V3.sol** (Execution Layer with Escrow Integration)
**Location**: `contracts/HydraChain/modules/Inspector/Inspector_V3.sol`

**Responsibilities**:
- Execute slashing using existing `penalizeStaker` pattern
- Transfer 100% of validator's stake to SlashingEscrow
- Ban the validator
- Maintain validator lifecycle

**Key Changes from V2**:
```solidity
// Reference to escrow contract
address public slashingEscrow;

// Modified slashValidator to use escrow
function slashValidator(address validator, string calldata reason) external onlySlashing {
    // 1. Get 100% of validator's stake
    uint256 penaltyAmount = hydraStakingContract.stakeOf(validator);

    // 2. Use penalizeStaker to transfer to THIS contract
    PenalizedStakeDistribution[] memory distributions = new PenalizedStakeDistribution[](1);
    distributions[0] = PenalizedStakeDistribution({
        account: address(this), // Send to Inspector first
        amount: penaltyAmount
    });
    hydraStakingContract.penalizeStaker(validator, distributions);

    // 3. Forward to SlashingEscrow with 30-day lock
    ISlashingEscrow(slashingEscrow).lockFunds{value: penaltyAmount}(validator);

    // 4. Ban validator
    _ban(validator);
}
```

**Why This Approach**:
- ✅ Reuses existing `penalizeStaker` infrastructure (minimizes changes)
- ✅ No modifications to HydraStaking.sol needed
- ✅ Clean separation: Inspector receives → forwards to Escrow
- ✅ Maintains compatibility with existing delegation/staking logic

---

### 3. **SlashingEscrow.sol** (NEW - Fund Lock & Governance Management)
**Location**: `contracts/HydraStaking/modules/Slashing/SlashingEscrow.sol`

**Responsibilities**:
- Hold slashed funds in escrow for 30 days
- Track lock period per validator
- Allow governance to decide: burn or send to DAO treasury
- Batch operations for gas efficiency

**Key Features**:
```solidity
// 30-day lock period
uint256 public constant LOCK_PERIOD = 30 days;

// Governance can withdraw after lock period
address public governance;
address public daoTreasury;

// Track locked funds per validator
struct LockedFunds {
    uint256 amount;          // Amount locked
    uint256 lockTimestamp;   // When locked
    bool withdrawn;          // Whether withdrawn
}
mapping(address => LockedFunds) public lockedFunds;
```

**Governance Functions**:

1. **Per-Validator Decision**:
```solidity
// Burn specific validator's funds
function burnLockedFunds(address validator) external onlyGovernance;

// Send specific validator's funds to DAO treasury
function sendToTreasury(address validator) external onlyGovernance;
```

2. **Batch Operations** (Gas Efficient):
```solidity
// Burn multiple validators' funds in one transaction
function batchBurnLockedFunds(address[] calldata validators) external onlyGovernance;

// Send multiple validators' funds to treasury in one transaction
function batchSendToTreasury(address[] calldata validators) external onlyGovernance;
```

3. **View Functions**:
```solidity
// Check if funds are unlocked
function isUnlocked(address validator) external view returns (bool);

// Get unlock timestamp
function getUnlockTime(address validator) external view returns (uint256);

// Get remaining lock time in seconds
function getRemainingLockTime(address validator) external view returns (uint256);
```

---

## Complete Slashing Flow

### Step-by-Step Execution:

```
1. Double-signing detected by consensus nodes
   ↓
2. Proposer creates slashing system transaction with evidence
   ↓
3. Slashing.slashValidator() called
   - Validates evidence structure
   - Verifies BLS signatures
   - Checks mass slashing limit
   - Stores evidence hash
   - Marks validator as slashed
   ↓
4. Slashing calls Inspector.slashValidator()
   ↓
5. Inspector.slashValidator() executes:
   - Gets 100% of validator's stake
   - Calls HydraStaking.penalizeStaker() with distribution to Inspector
   - HydraStaking transfers funds to Inspector
   - Inspector forwards funds to SlashingEscrow
   ↓
6. SlashingEscrow.lockFunds() locks funds for 30 days
   - Creates LockedFunds entry
   - Sets unlock timestamp = now + 30 days
   - Emits FundsLocked event
   ↓
7. Inspector bans validator
   - Validator status set to BANNED
   - Excluded from next epoch's validator set
   ↓
8. WAIT 30 DAYS...
   ↓
9. Governance decides (per validator):

   Option A: Burn
   → SlashingEscrow.burnLockedFunds(validator)
   → Funds sent to address(0)
   → Emits FundsBurned event

   Option B: DAO Treasury
   → SlashingEscrow.sendToTreasury(validator)
   → Funds sent to daoTreasury address
   → Emits FundsSentToTreasury event
```

---

## Key Design Decisions

### 1. **Why 100% Fixed Penalty?**
Per client discussion (Myra's comment):
> "It was agreed upon to have 100% slash in the event of double signing"

Double-signing is considered the most severe offense in PoS consensus, justifying maximum penalty.

### 2. **Why 30-Day Lock?**
Provides time for:
- Community discussion on fund destination
- Governance vote if needed
- Audit/investigation of the slashing event
- Prevents hasty decisions

### 3. **Why Per-Validator Decision?**
Different scenarios may warrant different outcomes:
- **Malicious attack** → Burn funds (stronger deterrent)
- **Configuration error** → Send to DAO (less punitive)
- **Mass event investigation** → Hold for further review

### 4. **Why Batch Operations?**
If multiple validators are slashed (e.g., configuration bug affecting multiple nodes):
- Gas-efficient to process many validators at once
- Governance can make consistent decisions across group
- Reduces transaction overhead

---

## Security Features

### 1. **Double Slashing Prevention**
```solidity
// In Slashing.sol
mapping(address => bool) private _hasBeenSlashed;

if (_hasBeenSlashed[validator]) revert ValidatorAlreadySlashed();
```

### 2. **Mass Slashing Protection**
```solidity
// In Slashing.sol
uint256 public maxSlashingsPerBlock;
mapping(uint256 => uint256) public slashingsInBlock;

if (slashingsInBlock[block.number] >= maxSlashingsPerBlock) {
    revert MaxSlashingsExceeded();
}
```

**Rationale**: Protects against bugs that could trigger mass slashing and destabilize the network.

**Recommended Setting**: `maxSlashingsPerBlock = 3` (adjustable by governance)

### 3. **Evidence Storage**
```solidity
// In Slashing.sol
mapping(address => bytes32) public slashingEvidenceHash;

slashingEvidenceHash[validator] = keccak256(abi.encode(msg1, msg2));
```

**Benefits**:
- Immutable audit trail
- Can verify slashing was legitimate
- Evidence hash stored on-chain forever
- Can reconstruct full evidence if needed (from events)

### 4. **Lock Period Enforcement**
```solidity
// In SlashingEscrow.sol
function _checkWithdrawable(address validator) internal view {
    uint256 unlockTime = lockedFunds[validator].lockTimestamp + LOCK_PERIOD;
    if (block.timestamp < unlockTime) {
        revert FundsStillLocked(unlockTime);
    }
}
```

Cannot bypass 30-day lock - enforced at contract level.

---

## Configuration Parameters

### Slashing.sol
```solidity
// Fixed at deployment
PENALTY_PERCENTAGE = 10000 (100%)

// Configurable by system
maxSlashingsPerBlock = 3 (recommended)
```

### SlashingEscrow.sol
```solidity
// Fixed at deployment
LOCK_PERIOD = 30 days

// Configurable by governance
governance = 0x... (governance address)
daoTreasury = 0x... (DAO treasury address)
```

---

## Events for Monitoring

### Slashing.sol
```solidity
event DoubleSignEvidence(
    address indexed validator,
    bytes32 evidenceHash,
    uint64 height,
    uint64 round,
    bytes32 msg1Hash,
    bytes32 msg2Hash
);

event ValidatorSlashed(address indexed validator, string reason);
event MaxSlashingsPerBlockUpdated(uint256 oldMax, uint256 newMax);
```

### SlashingEscrow.sol
```solidity
event FundsLocked(address indexed validator, uint256 amount, uint256 unlockTime);
event FundsBurned(address indexed validator, uint256 amount, address indexed burnedBy);
event FundsSentToTreasury(address indexed validator, uint256 amount, address indexed treasury);
event GovernanceUpdated(address indexed oldGovernance, address indexed newGovernance);
event DaoTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
```

### Inspector.sol
```solidity
event ValidatorSlashed(address indexed validator, string reason);
```

---

## Deployment Checklist

### 1. Deploy Contracts (in order)
```
1. Deploy SlashingEscrow
   - initialize(governanceAddr, daoTreasuryAddr)

2. Deploy Slashing
   - initialize(hydraChainAddr, slashingEscrowAddr, maxSlashingsPerBlock=3)

3. Update Inspector (in HydraChain)
   - setSlashingContract(slashingAddr)
   - setSlashingEscrow(slashingEscrowAddr)

4. Update Slashing
   - setBLSAddress(blsAddr)
```

### 2. Configuration
```
1. Set max slashings per block (recommended: 3)
   Slashing.setMaxSlashingsPerBlock(3)

2. Set DAO treasury address
   SlashingEscrow.setDaoTreasury(treasuryAddr)

3. Verify governance address
   SlashingEscrow.governance() == expectedGovernance
```

### 3. Integration with Node
```
1. Update consensus runtime to create slashing transactions
2. Include evidence in system transactions
3. Test with local devnet
4. Monitor events for proper execution
```

---

## Differences from Previous Versions

### V1 (Rejected)
- Custom fund management in Slashing contract
- Modified HydraStaking significantly
- Hardcoded 100% penalty

### V2 (Partially Accepted)
- Configurable penalty percentage (0-100%)
- Reused penalizeStaker pattern ✅
- No 30-day lock ❌
- No governance withdrawal ❌

### V3 (Final - This Version)
- Fixed 100% penalty ✅
- 30-day lock in escrow ✅
- Governance per-validator decision ✅
- Reuses penalizeStaker pattern ✅
- Mass slashing protection ✅
- Evidence storage ✅
- HydraStaking unchanged ✅

---

## Testing Recommendations

### Unit Tests
1. Test evidence validation (valid/invalid cases)
2. Test BLS signature verification
3. Test double slashing prevention
4. Test mass slashing protection
5. Test 30-day lock enforcement
6. Test governance withdrawal (burn vs treasury)
7. Test batch operations

### Integration Tests
1. Full slashing flow end-to-end
2. Validator removal from epoch
3. Funds transfer to escrow
4. Lock period expiry
5. Governance operations after lock period

### Edge Cases
1. Slashing at epoch boundary
2. Multiple slashings in same block
3. Slashing with zero stake (should fail)
4. Governance change during lock period
5. Re-slashing attempt (should fail)

---

## Open Questions (Pending Client Response)

### Validator Removal Timing
**Question**: Should slashed validators be removed from the active set:
- **Option A**: Immediately (by forcing epoch end in next block)?
- **Option B**: At natural epoch boundary?

**Current Status**: Waiting for client response. See message sent to client.

**Impact**:
- Option A requires consensus runtime changes
- Option B is simpler but leaves slashed validator active longer

---

## Summary

This V3 architecture fully implements all client requirements:

✅ **100% slash** - Fixed penalty for double signing
✅ **30-day lock** - Funds held in SlashingEscrow
✅ **Governance decision** - Burn or treasury per validator
✅ **Mass slashing protection** - Configurable limit per block
✅ **Evidence storage** - Immutable audit trail
✅ **Minimal changes** - Reuses existing patterns
✅ **HydraStaking unchanged** - No modifications needed

The architecture is secure, flexible, and ready for deployment pending client approval on the epoch termination strategy.
