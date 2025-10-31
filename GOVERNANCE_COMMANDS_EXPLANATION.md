# Governance Commands for Slashed Funds Withdrawal

## Yes, Commands Are Already Implemented! ✅

The governance can decide per-validator whether to **burn** or **send to DAO treasury** after the 30-day lock period.

---

## Available Commands (SlashingEscrow Contract)

### 1. **Burn Funds for Specific Validator** 🔥

**Command**: `burnLockedFunds(validatorAddress)`

**What it does**:
- Sends slashed funds to `address(0)` (permanently destroyed)
- Only works after 30-day lock expires
- Only callable by governance address

**Example**:
```solidity
// After 30 days have passed
SlashingEscrow.burnLockedFunds(0x123...abc);
// Result: 100 HYDRA burned (destroyed forever)
```

**Use case**: Malicious attack → destroy the slashed funds

---

### 2. **Send Funds to DAO Treasury** 💰

**Command**: `sendToTreasury(validatorAddress)`

**What it does**:
- Sends slashed funds to DAO treasury address
- Only works after 30-day lock expires
- Only callable by governance address

**Example**:
```solidity
// After 30 days have passed
SlashingEscrow.sendToTreasury(0x123...abc);
// Result: 100 HYDRA sent to DAO treasury
```

**Use case**: Configuration error → return funds to community treasury

---

### 3. **Batch Burn Multiple Validators** 🔥🔥🔥

**Command**: `batchBurnLockedFunds([validator1, validator2, validator3])`

**What it does**:
- Burns funds for multiple validators in one transaction
- Gas-efficient for mass slashing events
- Automatically skips validators that aren't ready (still locked or already withdrawn)

**Example**:
```solidity
address[] memory validators = [0x111...aaa, 0x222...bbb, 0x333...ccc];
SlashingEscrow.batchBurnLockedFunds(validators);
// Result: All unlocked validators' funds burned
```

**Use case**: Multiple validators from coordinated attack → burn all at once

---

### 4. **Batch Send to Treasury** 💰💰💰

**Command**: `batchSendToTreasury([validator1, validator2, validator3])`

**What it does**:
- Sends funds for multiple validators to treasury in one transaction
- Gas-efficient for mass slashing events
- Automatically skips validators that aren't ready

**Example**:
```solidity
address[] memory validators = [0x111...aaa, 0x222...bbb, 0x333...ccc];
SlashingEscrow.batchSendToTreasury(validators);
// Result: All unlocked validators' funds sent to DAO treasury
```

**Use case**: Multiple validators from same configuration bug → send to treasury

---

## Query Commands (Check Status)

### 5. **Check If Funds Are Unlocked**

**Command**: `isUnlocked(validatorAddress)`

**Returns**: `true` if 30 days passed, `false` otherwise

**Example**:
```solidity
bool ready = SlashingEscrow.isUnlocked(0x123...abc);
// Returns: true (can withdraw) or false (still locked)
```

---

### 6. **Get Unlock Timestamp**

**Command**: `getUnlockTime(validatorAddress)`

**Returns**: Unix timestamp when funds can be withdrawn

**Example**:
```solidity
uint256 unlockTime = SlashingEscrow.getUnlockTime(0x123...abc);
// Returns: 1730419200 (Unix timestamp)
// Convert to date: October 31, 2025, 12:00 PM
```

---

### 7. **Get Remaining Lock Time**

**Command**: `getRemainingLockTime(validatorAddress)`

**Returns**: Seconds remaining until unlock (0 if already unlocked)

**Example**:
```solidity
uint256 remaining = SlashingEscrow.getRemainingLockTime(0x123...abc);
// Returns: 259200 (3 days remaining)
// Or: 0 (already unlocked, ready to withdraw)
```

---

### 8. **Get Locked Funds Info**

**Command**: `lockedFunds(validatorAddress)`

**Returns**: Struct with `amount`, `lockTimestamp`, `withdrawn`

**Example**:
```solidity
(uint256 amount, uint256 lockTimestamp, bool withdrawn) =
    SlashingEscrow.lockedFunds(0x123...abc);

// Returns:
// amount: 100000000000000000000 (100 HYDRA in wei)
// lockTimestamp: 1727827200 (when locked)
// withdrawn: false (not yet withdrawn)
```

---

## Practical Workflow

### Scenario: Single Validator Slashed

**Day 0** (Validator slashed):
```
1. Validator caught double-signing
2. 100 HYDRA slashed and locked in SlashingEscrow
3. lockTimestamp = now
4. unlockTime = now + 30 days
```

**Day 1-29** (Lock period):
```
Governance checks status:
  SlashingEscrow.isUnlocked(validator) → false
  SlashingEscrow.getRemainingLockTime(validator) → 2,505,600 seconds (29 days)

Actions available: None (still locked)
```

**Day 30+** (After lock expires):
```
Governance checks status:
  SlashingEscrow.isUnlocked(validator) → true ✅
  SlashingEscrow.getRemainingLockTime(validator) → 0 ✅

Governance decides:

Option A: Burn
  SlashingEscrow.burnLockedFunds(validator)
  → 100 HYDRA destroyed forever

Option B: Send to Treasury
  SlashingEscrow.sendToTreasury(validator)
  → 100 HYDRA sent to DAO treasury
```

---

### Scenario: Mass Slashing Event (5 Validators)

**Day 0** (Multiple validators slashed):
```
Block 1000: Validator A slashed (100 HYDRA locked)
Block 1001: Validator B slashed (100 HYDRA locked)
Block 1002: Validator C slashed (100 HYDRA locked)
Block 1003: Validator D slashed (100 HYDRA locked)
Block 1004: Validator E slashed (100 HYDRA locked)

Total in escrow: 500 HYDRA
```

**Day 30+** (After investigation):
```
Governance investigation reveals:
- Validators A, B, C: Coordinated attack (malicious)
- Validators D, E: Configuration error (innocent mistake)

Governance decides:

Action 1: Burn malicious validators
  address[] memory malicious = [A, B, C];
  SlashingEscrow.batchBurnLockedFunds(malicious)
  → 300 HYDRA burned

Action 2: Return innocent validators' funds to treasury
  address[] memory innocent = [D, E];
  SlashingEscrow.batchSendToTreasury(innocent)
  → 200 HYDRA sent to DAO treasury

Result:
- Malicious actors punished (funds destroyed)
- Innocent errors compensated (funds to community)
```

---

## Access Control

### Who Can Call These Commands?

**Governance Only** ✅:
- `burnLockedFunds()`
- `sendToTreasury()`
- `batchBurnLockedFunds()`
- `batchSendToTreasury()`
- `setGovernance()` (transfer governance)
- `setDaoTreasury()` (update treasury address)

**System Only** (Inspector contract):
- `lockFunds()` (called during slashing)

**Anyone** (Read-only):
- `isUnlocked()`
- `getUnlockTime()`
- `getRemainingLockTime()`
- `lockedFunds()`

---

## Safety Checks (Built-In)

### 1. **30-Day Lock Enforcement** ⏰

```solidity
function _checkWithdrawable(address validator) internal view {
    uint256 unlockTime = lockedFunds[validator].lockTimestamp + LOCK_PERIOD;

    if (block.timestamp < unlockTime) {
        revert FundsStillLocked(unlockTime);
    }
}
```

**Result**: Cannot withdraw before 30 days, even if governance tries!

---

### 2. **Already Withdrawn Check** 🚫

```solidity
if (lockedFunds[validator].withdrawn) revert AlreadyWithdrawn();
```

**Result**: Cannot withdraw same validator's funds twice!

---

### 3. **No Funds Check** ❌

```solidity
if (lockedFunds[validator].amount == 0) revert NoLockedFunds();
```

**Result**: Cannot withdraw if no funds locked!

---

### 4. **Treasury Set Check** 🏦

```solidity
if (daoTreasury == address(0)) revert InvalidAddress();
```

**Result**: Cannot send to treasury if address not set!

---

## Example CLI Commands (For Governance)

### Using Cast (Foundry)

**1. Check if unlocked**:
```bash
cast call $ESCROW_ADDRESS "isUnlocked(address)(bool)" $VALIDATOR_ADDRESS
```

**2. Get remaining time**:
```bash
cast call $ESCROW_ADDRESS "getRemainingLockTime(address)(uint256)" $VALIDATOR_ADDRESS
```

**3. Burn funds** (after 30 days):
```bash
cast send $ESCROW_ADDRESS "burnLockedFunds(address)" $VALIDATOR_ADDRESS \
  --from $GOVERNANCE_ADDRESS \
  --private-key $GOVERNANCE_KEY
```

**4. Send to treasury** (after 30 days):
```bash
cast send $ESCROW_ADDRESS "sendToTreasury(address)" $VALIDATOR_ADDRESS \
  --from $GOVERNANCE_ADDRESS \
  --private-key $GOVERNANCE_KEY
```

**5. Batch burn**:
```bash
cast send $ESCROW_ADDRESS "batchBurnLockedFunds(address[])" \
  "[$VALIDATOR1,$VALIDATOR2,$VALIDATOR3]" \
  --from $GOVERNANCE_ADDRESS \
  --private-key $GOVERNANCE_KEY
```

---

### Using Web3 (JavaScript)

```javascript
const escrow = new web3.eth.Contract(SlashingEscrowABI, escrowAddress);

// Check if unlocked
const isUnlocked = await escrow.methods.isUnlocked(validatorAddress).call();

// Get remaining time
const remaining = await escrow.methods.getRemainingLockTime(validatorAddress).call();
console.log(`Remaining: ${remaining} seconds`);

// Burn funds (after 30 days)
await escrow.methods.burnLockedFunds(validatorAddress)
  .send({ from: governanceAddress });

// Send to treasury (after 30 days)
await escrow.methods.sendToTreasury(validatorAddress)
  .send({ from: governanceAddress });

// Batch burn
await escrow.methods.batchBurnLockedFunds([validator1, validator2, validator3])
  .send({ from: governanceAddress });
```

---

## Events Emitted

### When Funds Are Locked
```solidity
event FundsLocked(
    address indexed validator,
    uint256 amount,
    uint256 unlockTime
);
```

### When Funds Are Burned
```solidity
event FundsBurned(
    address indexed validator,
    uint256 amount,
    address indexed burnedBy
);
```

### When Funds Sent to Treasury
```solidity
event FundsSentToTreasury(
    address indexed validator,
    uint256 amount,
    address indexed treasury
);
```

**Use case**: Monitor these events to track governance decisions

---

## Summary for Your Client

### ✅ Yes, Commands Are Implemented!

**Per-Validator Control**:
- ✅ `burnLockedFunds(validator)` - Burn specific validator's funds
- ✅ `sendToTreasury(validator)` - Send specific validator's funds to DAO

**Batch Control** (for mass slashing):
- ✅ `batchBurnLockedFunds([...validators])` - Burn multiple at once
- ✅ `batchSendToTreasury([...validators])` - Send multiple to treasury

**Query/Status**:
- ✅ `isUnlocked(validator)` - Check if 30 days passed
- ✅ `getRemainingLockTime(validator)` - How long until unlock
- ✅ `getUnlockTime(validator)` - Exact unlock timestamp

**Safety**:
- ✅ 30-day lock enforced (cannot bypass)
- ✅ Only governance can withdraw
- ✅ Cannot withdraw twice
- ✅ Events for transparency

**Everything is ready!** Governance just needs to wait 30 days, then decide burn vs treasury per validator.
