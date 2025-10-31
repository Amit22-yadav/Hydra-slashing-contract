# Slashing V3 Flow Diagram

## Complete Flow Visualization

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     SLASHING EXECUTION FLOW                             │
└─────────────────────────────────────────────────────────────────────────┘

┌──────────────┐
│  Consensus   │  Detects double-signing
│    Nodes     │  Collects evidence (msg1, msg2)
└──────┬───────┘
       │
       │ Create system transaction
       ▼
┌────────────────────────────────────────────────────────────────────────┐
│                    SLASHING.SOL (Validation Layer)                     │
│                                                                        │
│  slashValidator(validator, msg1, msg2, reason)                        │
│                                                                        │
│  ✓ Validate evidence structure                                        │
│    - Same height, round, type                                         │
│    - Different data (conflicting messages)                            │
│                                                                        │
│  ✓ Verify BLS signatures                                              │
│    - Get validator's public key                                       │
│    - Verify both messages signed by validator                         │
│                                                                        │
│  ✓ Check protection limits                                            │
│    - Not already slashed                                              │
│    - Max slashings per block not exceeded                             │
│                                                                        │
│  ✓ Store evidence                                                     │
│    - evidenceHash = keccak256(msg1, msg2)                             │
│                                                                        │
│  ✓ Mark as slashed                                                    │
│    - _hasBeenSlashed[validator] = true                                │
│                                                                        │
└────────────┬───────────────────────────────────────────────────────────┘
             │
             │ Call Inspector.slashValidator()
             ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   INSPECTOR.SOL (Execution Layer)                      │
│                                                                        │
│  slashValidator(validator, reason)                                    │
│                                                                        │
│  Step 1: Get validator's stake                                        │
│  ┌─────────────────────────────────────┐                              │
│  │ currentStake = stakeOf(validator)   │                              │
│  │ penaltyAmount = currentStake (100%) │                              │
│  └─────────────────────────────────────┘                              │
│                                                                        │
│  Step 2: Create penalty distribution                                  │
│  ┌──────────────────────────────────────────────┐                     │
│  │ distributions[0] = {                         │                     │
│  │   account: address(this), // Inspector      │                     │
│  │   amount: penaltyAmount                      │                     │
│  │ }                                            │                     │
│  └──────────────────────────────────────────────┘                     │
│                │                                                       │
└────────────────┼───────────────────────────────────────────────────────┘
                 │
                 │ Call HydraStaking.penalizeStaker()
                 ▼
┌────────────────────────────────────────────────────────────────────────┐
│              HYDRASTAKING.SOL (Existing - Unchanged)                   │
│                                                                        │
│  penalizeStaker(validator, distributions)                             │
│                                                                        │
│  ✓ Remove stake from validator                                        │
│  ✓ Transfer funds to distribution recipients                          │
│                                                                        │
│  Transfer penaltyAmount to Inspector ───────────────────┐             │
│                                                          │             │
└──────────────────────────────────────────────────────────┼─────────────┘
                                                           │
                                      Funds arrive at Inspector
                                                           │
┌──────────────────────────────────────────────────────────┼─────────────┐
│                   INSPECTOR.SOL (continued)              │             │
│                                                          │             │
│  Step 3: Forward to SlashingEscrow                      │             │
│  ┌──────────────────────────────────────────────────────▼──────────┐  │
│  │ ISlashingEscrow(escrow).lockFunds{value: penalty}(validator)   │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  Step 4: Ban validator                                                │
│  ┌─────────────────────────────────────┐                              │
│  │ _ban(validator)                     │                              │
│  │ - Set status to BANNED              │                              │
│  │ - Exclude from next epoch           │                              │
│  └─────────────────────────────────────┘                              │
│                                                                        │
└────────────────┬───────────────────────────────────────────────────────┘
                 │
                 │ Forward funds with lockFunds()
                 ▼
┌────────────────────────────────────────────────────────────────────────┐
│               SLASHINGESCROW.SOL (30-Day Lock)                         │
│                                                                        │
│  lockFunds(validator) payable                                         │
│                                                                        │
│  ✓ Receive slashed funds                                              │
│  ✓ Create lock entry                                                  │
│  ┌──────────────────────────────────────────┐                         │
│  │ lockedFunds[validator] = {               │                         │
│  │   amount: msg.value,                     │                         │
│  │   lockTimestamp: block.timestamp,        │                         │
│  │   withdrawn: false                       │                         │
│  │ }                                        │                         │
│  └──────────────────────────────────────────┘                         │
│                                                                        │
│  ✓ Set unlock time                                                    │
│  unlockTime = block.timestamp + 30 days                               │
│                                                                        │
│  ✓ Emit event                                                         │
│  emit FundsLocked(validator, amount, unlockTime)                      │
│                                                                        │
└────────────────┬───────────────────────────────────────────────────────┘
                 │
                 │ ⏰ WAIT 30 DAYS...
                 │
                 ▼
┌────────────────────────────────────────────────────────────────────────┐
│           GOVERNANCE DECISION (After 30-Day Lock Expires)              │
│                                                                        │
│  Two Options:                                                         │
│                                                                        │
│  OPTION A: BURN FUNDS                   OPTION B: SEND TO DAO         │
│  ┌──────────────────────────┐          ┌──────────────────────────┐  │
│  │ burnLockedFunds()        │          │ sendToTreasury()         │  │
│  │                          │          │                          │  │
│  │ Check:                   │          │ Check:                   │  │
│  │ ✓ Lock expired           │          │ ✓ Lock expired           │  │
│  │ ✓ Not withdrawn          │          │ ✓ Not withdrawn          │  │
│  │                          │          │ ✓ Treasury set           │  │
│  │ Action:                  │          │                          │  │
│  │ Send to address(0)       │          │ Action:                  │  │
│  │                          │          │ Send to daoTreasury      │  │
│  │ Emit:                    │          │                          │  │
│  │ FundsBurned              │          │ Emit:                    │  │
│  │                          │          │ FundsSentToTreasury      │  │
│  └──────────────────────────┘          └──────────────────────────┘  │
│                                                                        │
│  Batch Operations Available:                                          │
│  ┌────────────────────────────────────────────────────┐               │
│  │ batchBurnLockedFunds(validators[])                 │               │
│  │ batchSendToTreasury(validators[])                  │               │
│  │                                                    │               │
│  │ (Gas efficient for multiple validators)           │               │
│  └────────────────────────────────────────────────────┘               │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Timeline Example

```
Block N: Double-signing detected
         │
         ├─ Slashing.slashValidator() called
         │  - Evidence validated ✓
         │  - BLS signatures verified ✓
         │
         ├─ Inspector.slashValidator() executes
         │  - 100% stake removed from validator
         │  - Funds sent to SlashingEscrow
         │  - Validator banned
         │
         └─ Funds locked in escrow
            unlockTime = now + 30 days

------- 30 DAYS LATER -------

Block N+259200: Lock period expires
                │
                ├─ Governance can now withdraw
                │
                ├─ Decision A: burnLockedFunds(validator)
                │              → Funds destroyed ✓
                │
                └─ Decision B: sendToTreasury(validator)
                               → Funds to DAO ✓
```

---

## State Changes

### Validator State
```
Before:
  validators[addr].status = Active
  validators[addr].stake = 100 HYDRA

After Slashing:
  validators[addr].status = Banned
  validators[addr].stake = 0 HYDRA

After 30 Days + Governance Action:
  (State unchanged, funds distributed)
```

### Funds Flow
```
Initial:    Validator Stake = 100 HYDRA

Step 1:     HydraStaking removes 100 HYDRA from validator
Step 2:     HydraStaking sends 100 HYDRA to Inspector
Step 3:     Inspector forwards 100 HYDRA to SlashingEscrow

            SlashingEscrow holds: 100 HYDRA
            Lock expires: block.timestamp + 30 days

After Lock: Governance chooses:
            - Burn: SlashingEscrow sends to address(0) → 100 HYDRA destroyed
            - Treasury: SlashingEscrow sends to DAO → DAO receives 100 HYDRA
```

---

## Protection Mechanisms

### 1. Double Slashing Prevention
```
First slash:  _hasBeenSlashed[validator] = false → ✓ Allow
              _hasBeenSlashed[validator] = true

Second slash: _hasBeenSlashed[validator] = true → ✗ Reject
              revert ValidatorAlreadySlashed()
```

### 2. Mass Slashing Protection
```
Block N:
  maxSlashingsPerBlock = 3
  slashingsInBlock[N] = 0

Slash #1: slashingsInBlock[N] = 1 → ✓ Allow
Slash #2: slashingsInBlock[N] = 2 → ✓ Allow
Slash #3: slashingsInBlock[N] = 3 → ✓ Allow
Slash #4: slashingsInBlock[N] = 3 >= maxSlashingsPerBlock → ✗ Reject
          revert MaxSlashingsExceeded()
```

### 3. Lock Period Enforcement
```
Lock created: lockTimestamp = 1000
              unlockTime = 1000 + 30 days = 1000 + 2592000 = 2593000

At time 2000000 (before unlock):
  isUnlocked() = false → ✗ Cannot withdraw
  Governance calls burnLockedFunds() → revert FundsStillLocked(2593000)

At time 2593000 (after unlock):
  isUnlocked() = true → ✓ Can withdraw
  Governance calls burnLockedFunds() → ✓ Success
```

---

## Error Handling

```
┌─────────────────────────┬──────────────────────────────────────┐
│ Error                   │ When It Occurs                       │
├─────────────────────────┼──────────────────────────────────────┤
│ ValidatorAlreadySlashed │ Trying to slash same validator twice │
│ EvidenceMismatch        │ Invalid evidence structure           │
│ BLS signature invalid   │ Invalid BLS signature verification   │
│ MaxSlashingsExceeded    │ Too many slashings in one block      │
│ FundsStillLocked        │ Trying to withdraw before 30 days   │
│ AlreadyWithdrawn        │ Trying to withdraw funds twice       │
│ NoLockedFunds           │ No funds locked for validator        │
└─────────────────────────┴──────────────────────────────────────┘
```

---

## Key Points

✅ **100% penalty** - Fixed, not configurable
✅ **30-day lock** - Cannot be bypassed
✅ **Per-validator governance decision** - Burn or treasury
✅ **Reuses existing infrastructure** - HydraStaking unchanged
✅ **Multiple protection layers** - Double slashing, mass slashing, lock period
✅ **Complete audit trail** - Evidence hash stored on-chain
