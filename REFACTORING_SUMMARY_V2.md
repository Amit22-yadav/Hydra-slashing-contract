# Slashing Contract Architecture Refactoring V2 - Minimal Changes Approach

## Overview

This refactoring addresses client concerns while **minimizing code changes** by **reusing existing infrastructure** (Inspector + PenalizedStakeDistribution pattern).

## Client Requirements (from thread)

1. **Reuse existing Inspector module + PenalizedStakeDistribution pattern**
   - Minimize code changes to reduce bug risk
   - Leverage existing penalizeStaker() infrastructure

2. **Configurable penalty percentage**
   - NOT hardcoded 100%
   - Allow starting with minor penalty (or even 0%)
   - Governance can adjust over time

3. **Fund destination decision needed**
   - Burn (address(0)) OR absorb by DAO treasury?
   - Currently implemented as burn per discussion

4. **Protection against mass slashing**
   - Bug in system could slash too many validators
   - Would harm chain reputation and decentralization
   - Need limits on slashings per block

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Slashing Contract (Evidence Validation Layer)                   │
│ ─────────────────────────────────────────────────────────────── │
│ ✅ Validates double-signing evidence (BLS signatures)            │
│ ✅ Stores evidence hash for auditing                             │
│ ✅ Configurable penalty percentage (0-100%)                      │
│ ✅ Max slashings per block protection                            │
│ ✅ Prevents double slashing                                      │
│ ✅ Thin validation layer - delegates to Inspector                │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       │ slashValidator(validator, reason)
                       ↓
┌─────────────────────────────────────────────────────────────────┐
│ Inspector Contract (Existing Infrastructure - REUSED)           │
│ ─────────────────────────────────────────────────────────────── │
│ ✅ Receives slashValidator() call from Slashing contract         │
│ ✅ Reads penalty % from Slashing contract                        │
│ ✅ Calculates penalty amount                                     │
│ ✅ Calls existing penalizeStaker() with PenalizedStakeDistribution│
│ ✅ Calls existing _ban() logic                                   │
│ ✅ MINIMAL changes to existing code                              │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       │ penalizeStaker(validator, distributions[])
                       ↓
┌─────────────────────────────────────────────────────────────────┐
│ HydraStaking Contract (UNCHANGED)                               │
│ ─────────────────────────────────────────────────────────────── │
│ ✅ Existing penalizeStaker() handles fund distribution           │
│ ✅ Existing PenalizedStakeDistribution pattern                   │
│ ❌ NO new slashing-specific code added                           │
│ ❌ NO modifications required                                     │
└─────────────────────────────────────────────────────────────────┘
```

## Key Differences from V1

| Aspect | V1 (Full Refactor) | V2 (Minimal Changes) |
|--------|-------------------|----------------------|
| **Slashing logic location** | Slashing contract | Slashing + Inspector |
| **Fund management** | Custom in Slashing | Reuse penalizeStaker |
| **HydraStaking changes** | Removed slashing code | NO changes |
| **Inspector changes** | Callback only | Enhanced slashValidator |
| **Penalty configuration** | Hardcoded 100% | Configurable 0-100% |
| **Code risk** | Medium (new patterns) | Low (reuse existing) |

## Files Modified

### 1. **Slashing.sol** - Thin Validation Layer

**Key Changes**:
- ✅ Evidence validation only (no fund management)
- ✅ `doubleSignPenaltyPercentage` - configurable (basis points)
- ✅ `maxSlashingsPerBlock` - protection against mass slashing
- ✅ `slashingsInBlock` - tracks slashings per block
- ✅ `setPenaltyPercentage()` - governance can adjust
- ✅ `setMaxSlashingsPerBlock()` - governance can adjust
- ✅ Delegates to `Inspector.slashValidator()` (not direct fund handling)

**What it DOESN'T do** (compared to V1):
- ❌ NO direct calls to HydraStaking
- ❌ NO fund burning logic
- ❌ NO unstaking logic
- ❌ NO slashed amounts tracking (Inspector handles it)

**Flow**:
```solidity
1. Validate evidence
2. Verify BLS signatures
3. Check mass slashing protection
4. Store evidence hash
5. Mark as slashed
6. Increment block counter
7. Emit DoubleSignEvidence event
8. Call Inspector.slashValidator(validator, reason)  // Delegate
9. Emit ValidatorSlashed event
```

### 2. **Inspector.sol** - Enhanced but Reusing Existing Pattern

**Key Changes**:
- ✅ `slashValidator()` enhanced to work with Slashing contract
- ✅ Reads penalty % from Slashing via `_getPenaltyPercentage()`
- ✅ Calculates penalty amount dynamically
- ✅ **Reuses existing `penalizeStaker()` + `PenalizedStakeDistribution`**
- ✅ **Reuses existing `_ban()` logic**
- ✅ Minimal modifications to existing flow

**What changed**:
```solidity
function slashValidator(validator, reason) onlySlashing {
    // Get current stake
    uint256 currentStake = hydraStakingContract.stakeOf(validator);

    // Get penalty % from Slashing contract (configurable!)
    uint256 penaltyPercentage = _getPenaltyPercentage();

    // Calculate penalty
    uint256 penaltyAmount = (currentStake * penaltyPercentage) / 10000;

    // REUSE EXISTING PATTERN
    PenalizedStakeDistribution[] memory distributions = ...;
    distributions[0] = PenalizedStakeDistribution({
        account: address(0),  // Burn (or DAO treasury - governance decision)
        amount: penaltyAmount
    });

    // REUSE EXISTING METHOD
    hydraStakingContract.penalizeStaker(validator, distributions);

    // REUSE EXISTING METHOD
    _ban(validator);
}
```

**What it DOESN'T change**:
- ❌ NO changes to `_ban()` logic
- ❌ NO changes to initiateBan/terminateBan/banValidator
- ❌ NO new fund management code
- ❌ Existing penalizeStaker pattern unchanged

### 3. **HydraStaking.sol** - NO CHANGES REQUIRED

**Status**: ✅ **UNCHANGED** (exactly what client wanted!)

- ✅ Existing `penalizeStaker()` handles everything
- ✅ Existing `PenalizedStakeDistribution` pattern works as-is
- ✅ NO new slashing-specific code
- ✅ NO modifications to existing logic
- ✅ Zero risk of introducing bugs here

### 4. **IInspector.sol** - Minor Update

**Changes**:
- ✅ Added `hasBeenSlashed()` view function to interface
- ✅ Kept existing `slashValidator()` signature

---

## Addressing Client Concerns

### 1. Reuse existing Inspector + PenalizedStakeDistribution

✅ **DONE** - Inspector's `slashValidator()` now:
- Reads penalty % from Slashing contract
- Calls existing `penalizeStaker()` with `PenalizedStakeDistribution`
- Calls existing `_ban()` logic
- **Zero changes** to HydraStaking required

### 2. Configurable Penalty Percentage

✅ **DONE** - Slashing contract has:
```solidity
// Stored in basis points (10000 = 100%)
uint256 public doubleSignPenaltyPercentage;

// Governance can update
function setPenaltyPercentage(uint256 newPercentage) onlySystemCall

// Examples:
// 0     = 0% penalty (warning only)
// 500   = 5% penalty
// 1000  = 10% penalty
// 10000 = 100% penalty (full stake)
```

**Recommendation**: Start with **low percentage** (5-10%) and monitor.

### 3. Fund Destination Decision

**Current Implementation**: Burns to `address(0)`

**Easy to change**:
```solidity
// In Inspector.slashValidator():
distributions[0] = PenalizedStakeDistribution({
    account: address(0),        // Burns
    // OR
    account: DAO_TREASURY,      // To DAO treasury
    amount: penaltyAmount
});
```

**Action Required**: Team needs to decide burn vs. treasury.

### 4. Protection Against Mass Slashing

✅ **DONE** - Multiple protections:

**A. Per-Block Limit**:
```solidity
uint256 public maxSlashingsPerBlock;  // e.g., 3

// In slashValidator():
if (slashingsInBlock[block.number] >= maxSlashingsPerBlock) {
    revert MaxSlashingsExceeded();
}
```

**B. Double Slashing Prevention**:
```solidity
mapping(address => bool) private _hasBeenSlashed;

if (_hasBeenSlashed[validator]) {
    revert ValidatorAlreadySlashed();
}
```

**C. Evidence Validation**:
- BLS signature verification
- Message data must differ
- Height/round must match

**Recommendation**: Set `maxSlashingsPerBlock = 3` initially.

### 5. Avoid Accidentally Slashing Dual Nodes

**Client Concern**: "A validator can mistakenly run two nodes and then lose its whole stake"

**Solutions Implemented**:
1. ✅ Configurable penalty (start low, e.g., 10%)
2. ✅ Evidence storage for auditing/appeals
3. ✅ Per-block limits prevent cascading failures

**Additional Recommendation**: Consider adding:
- Grace period for first offense (e.g., 5% penalty)
- Escalating penalties for repeat offenses
- Off-chain monitoring to detect dual nodes before slashing

---

## Configuration Recommendations

### Initial Deployment

```solidity
// Conservative approach
doubleSignPenaltyPercentage: 1000,  // 10% penalty
maxSlashingsPerBlock: 3              // Max 3 per block
```

### Gradual Increase (if needed)

| Phase | Penalty % | Rationale |
|-------|-----------|-----------|
| Phase 1 (Month 1-3) | 10% | Learning period, avoid harsh penalties |
| Phase 2 (Month 4-6) | 25% | Increase as network matures |
| Phase 3 (Month 7+) | 50% | Consider if attacks increase |
| Never? | 100% | Too harsh for accidental dual nodes |

---

## Benefits of Minimal Changes Approach

### 1. **Lower Risk**
- Reuses battle-tested `penalizeStaker` code
- No modifications to HydraStaking (0 risk)
- Minimal changes to Inspector
- Only Slashing contract is new

### 2. **Flexibility**
- Penalty adjustable by governance
- Fund destination easily changeable
- Mass slashing protections configurable
- Can start conservative and adjust

### 3. **Separation of Concerns**
- **Slashing**: Evidence validation + configuration
- **Inspector**: Execution using existing patterns
- **HydraStaking**: Unchanged accounting

### 4. **Backwards Compatible**
- Existing `penalizeStaker` pattern unchanged
- Existing `_ban()` logic unchanged
- Other ban mechanisms (downtime) still work

---

## Testing Checklist

- [ ] Deploy Slashing contract with low penalty (10%)
- [ ] Verify penalty percentage can be read
- [ ] Slash validator with valid evidence
- [ ] Verify penalty amount is 10% of stake
- [ ] Verify funds go to address(0) (or treasury)
- [ ] Verify validator is banned
- [ ] Attempt double slashing → should revert
- [ ] Slash 3 validators in one block → OK
- [ ] Attempt 4th slashing → should revert (MaxSlashingsExceeded)
- [ ] Update penalty percentage via governance
- [ ] Verify new percentage is applied
- [ ] Test with penalty = 0% (warning only)
- [ ] Verify evidence hash is stored
- [ ] Check hasBeenSlashed() returns true

---

## Open Questions for Team Decision

### 1. **Penalty Percentage**
- Start at 0% (warning only)?
- Start at 5-10% (minor penalty)?
- Start at 25-50% (moderate penalty)?

**Recommendation**: Start at **10%** for first 3 months.

### 2. **Fund Destination**
- Burn to address(0)?
- Send to DAO treasury?
- Split between burn + treasury?

**Recommendation**: **Burn** initially for simplicity. Can change later.

### 3. **Max Slashings Per Block**
- 1 (very conservative)?
- 3 (recommended)?
- 5 (permissive)?
- Unlimited (risky)?

**Recommendation**: Start with **3**, increase if needed.

### 4. **Grace Period for First Offense**
- Implement escalating penalties?
- First offense: 5%, Second: 25%, Third: 100%?
- Or keep flat rate?

**Recommendation**: Keep flat rate initially, add escalation later if needed.

---

## Summary

This V2 refactoring:
✅ Reuses existing Inspector + PenalizedStakeDistribution pattern
✅ Minimizes code changes (HydraStaking unchanged!)
✅ Configurable penalty (0-100%)
✅ Protection against mass slashing
✅ Flexible fund destination
✅ Low risk approach
✅ Evidence storage for auditing
✅ Backwards compatible

The architecture respects client's concerns about minimizing modifications and reusing existing infrastructure while still addressing all the security and functionality requirements.

**Next Steps**:
1. Team decides on penalty %, fund destination, max slashings
2. Deploy contracts with chosen parameters
3. Monitor for 3 months
4. Adjust parameters based on real-world data
