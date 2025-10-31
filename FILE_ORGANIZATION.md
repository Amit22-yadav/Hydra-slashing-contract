# File Organization Summary

## Final Contract Structure

The contract files have been organized for production deployment. Here's the current structure:

---

## 📁 Contracts/HydraStaking/modules/Slashing/

### **Active Contracts** (Ready for Deployment)

1. **[Slashing.sol](contracts/HydraStaking/modules/Slashing/Slashing.sol)** ✅
   - Final implementation with V3 features
   - 100% fixed penalty
   - Integrates with SlashingEscrow
   - Mass slashing protection
   - Evidence validation & BLS signature verification

2. **[SlashingEscrow.sol](contracts/HydraStaking/modules/Slashing/SlashingEscrow.sol)** ✅ (NEW)
   - 30-day lock on slashed funds
   - Governance withdrawal (burn OR treasury)
   - Batch operations for gas efficiency

3. **[ISlashing.sol](contracts/HydraStaking/modules/Slashing/ISlashing.sol)** ✅
   - Interface definition
   - Event definitions

### **Backup Contracts** (For Reference)

4. **Slashing_V2_BACKUP.sol** 📦
   - Previous version (configurable penalty)
   - Kept for reference
   - **DO NOT USE in production**

---

## 📁 Contracts/HydraChain/modules/Inspector/

### **Active Contracts** (Ready for Deployment)

1. **[Inspector.sol](contracts/HydraChain/modules/Inspector/Inspector.sol)** ✅
   - Final implementation with V3 features
   - Executes slashing using penalizeStaker pattern
   - Forwards 100% of stake to SlashingEscrow
   - Bans validators

2. **[IInspector.sol](contracts/HydraChain/modules/Inspector/IInspector.sol)** ✅
   - Interface definition

### **Backup Contracts** (For Reference)

3. **Inspector_V2_BACKUP.sol** 📦
   - Previous version (no escrow integration)
   - Kept for reference
   - **DO NOT USE in production**

---

## What Changed?

### ✅ **Promoted to Production**
- `Slashing_V3.sol` → `Slashing.sol`
- `Inspector_V3.sol` → `Inspector.sol`

### 📦 **Archived as Backups**
- `Slashing.sol` → `Slashing_V2_BACKUP.sol`
- `Inspector.sol` → `Inspector_V2_BACKUP.sol`

### ✨ **Created New**
- `SlashingEscrow.sol` (brand new contract)

---

## Code Quality

### Linter Issues Fixed ✅

1. **Removed unused import** in Inspector.sol:
   - Removed: `import {IHydraStaking} from "../../../HydraStaking/IHydraStaking.sol";`
   - Not needed since we access via `hydraStakingContract` reference

2. **Replaced require with custom error** in Inspector.sol:
   - Before: `require(currentStake > 0, "No stake to slash");`
   - After: `if (currentStake == 0) revert NoStakeToSlash();`
   - Added custom error: `error NoStakeToSlash();`

### Contract Title Updates ✅

Updated documentation comments to remove "V3" suffix:
- `@title Slashing V3` → `@title Slashing`
- `@title Inspector V3` → `@title Inspector`

---

## Deployment Checklist

When deploying these contracts, use:

### 1. Deploy in Order:
```
1. SlashingEscrow.sol
   ↓
2. Slashing.sol (reference SlashingEscrow address)
   ↓
3. Update Inspector.sol (set slashingContract and slashingEscrow addresses)
```

### 2. Configuration:
```solidity
// SlashingEscrow
initialize(governanceAddr, daoTreasuryAddr)

// Slashing
initialize(hydraChainAddr, slashingEscrowAddr, maxSlashingsPerBlock=3)
setBLSAddress(blsAddr)

// Inspector (via HydraChain)
setSlashingContract(slashingAddr)
setSlashingEscrow(slashingEscrowAddr)
```

---

## Version History

### V1 (Rejected)
- Custom fund management in Slashing contract
- Modified HydraStaking significantly
- Client rejected due to too many changes

### V2 (Partially Accepted)
- Configurable penalty percentage
- Reused penalizeStaker pattern ✅
- Missing: 30-day lock, governance withdrawal
- Now in `*_V2_BACKUP.sol` files

### V3 (Final - Current Production)
- Fixed 100% penalty ✅
- 30-day lock in SlashingEscrow ✅
- Governance per-validator decision ✅
- Reuses penalizeStaker pattern ✅
- Mass slashing protection ✅
- Evidence storage ✅
- Now in `Slashing.sol` and `Inspector.sol`

---

## How to Identify Versions

### In Code:
```solidity
// Production (Current)
contract Slashing is ISlashing, System, Initializable {
    uint256 public constant PENALTY_PERCENTAGE = 10000; // 100% fixed
    address public slashingEscrow; // Has escrow integration
}

// V2 Backup (Old)
contract Slashing is ISlashing, System, Initializable {
    uint256 public doubleSignPenaltyPercentage; // Configurable
    // No slashingEscrow reference
}
```

### By Features:
| Feature | V2 Backup | V3 Production |
|---------|-----------|---------------|
| Penalty | Configurable 0-100% | Fixed 100% |
| Lock Period | None | 30 days |
| Escrow Contract | No | Yes (SlashingEscrow.sol) |
| Governance Withdrawal | No | Yes (burn or treasury) |
| File Name | `*_V2_BACKUP.sol` | `*.sol` |

---

## Safety Notes

⚠️ **IMPORTANT**:
- Only deploy contracts from `*.sol` files (without version suffixes)
- `*_V2_BACKUP.sol` files are for reference only
- Do NOT mix V2 and V3 contracts (they're incompatible)

✅ **Production-Ready Files**:
- `Slashing.sol`
- `SlashingEscrow.sol`
- `Inspector.sol`
- `ISlashing.sol`
- `IInspector.sol`

❌ **Backup Files (Do Not Deploy)**:
- `Slashing_V2_BACKUP.sol`
- `Inspector_V2_BACKUP.sol`

---

## Next Steps

1. ✅ **Contract organization complete**
2. ✅ **Linter warnings fixed**
3. ⏳ **Waiting for client response** on epoch termination strategy
4. 🔜 **Node-side integration** (after client decision)
5. 🔜 **Testing & deployment**

---

## Questions?

If you need to:
- Restore V2 contracts → Rename `*_V2_BACKUP.sol` back to `*.sol`
- Compare versions → Use diff tool on `*.sol` vs `*_V2_BACKUP.sol`
- Understand architecture → See `SLASHING_V3_ARCHITECTURE.md`
- See flow diagrams → See `FLOW_DIAGRAM.md`

All documentation is in the `Hydra-slashing-contract/` directory.
