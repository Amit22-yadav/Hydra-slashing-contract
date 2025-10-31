# Message for Client: Industry Research on Double-Signing Validator Removal

---

**Re: Your question - "Are we saying that in all other chains, when a validator double signs, it is instantly banned mid Epoch, but is removed from the validator set at the End of the Epoch?"**

---

Hi Myra,

Great question! We did comprehensive research on how major PoS chains handle double-signing, and the answer is **No - this is NOT the universal approach**.

## Quick Summary

Most major chains **do NOT remove validators mid-epoch**. Here's what actually happens:

| Chain | Remove Mid-Epoch? | When Removed? | Approach |
|-------|-------------------|---------------|----------|
| **Cosmos/Tendermint** | ❌ No | Next epoch boundary | Slash immediately, remove at epoch end |
| **Ethereum 2.0** | ❌ No | After 8,192 epochs (~36 days) | Slash immediately, long delay before removal |
| **Polygon PoS** | ❌ No (when implemented) | Next span boundary | Will slash immediately, remove at span end |
| **BNB Smart Chain** | ✅ **Yes** | **Immediately** | **Only major chain that does instant removal** |
| **Avalanche** | ❌ No slashing on Primary Net | Subnet-dependent | No default slashing |

## Industry Standard: Wait for Epoch Boundary

**What most chains do**:
1. ✅ **Slash stake immediately** (financial penalty applied right away)
2. ✅ **Mark validator as "slashed" or "jailed"**
3. ✅ **Validator remains in active set** until epoch ends
4. ✅ **Remove from validator set** at next epoch boundary

**Why they do this**:
- Maintains BFT quorum calculations (requires fixed N validators)
- Prevents consensus disruption
- Ensures deterministic leader election
- Allows graceful validator set transitions
- Proven approach with years of production experience

**Example from Cosmos documentation**:
> "For fairness of deterministic leader election, applying a slash or jailing within an epoch would break the guarantee we were seeking to provide"

**Example from Ethereum**:
> "To avoid large changes in the validator set in a short amount of time, there are mechanisms limiting how many validators can be activated or exited within an epoch"

## The Exception: BNB Smart Chain

**Only BSC removes validators instantly mid-epoch.**

Why BSC can do this:
- Small validator set (21 validators)
- Short epochs (20 minutes)
- Modified consensus (Parlia, not pure BFT)
- Centralized validator selection

Why this is risky for us:
- Hydragon uses IBFT (pure BFT consensus)
- Requires fixed validator set for 2/3+ quorum calculations
- Removing validator mid-epoch changes quorum math
- Can break consensus safety guarantees

## Our Recommendation

**Follow the industry standard approach** (used by Cosmos, Ethereum, future Polygon):

### What Happens When Double-Signing Detected:

**Immediate Actions** (same block):
1. ✅ Slash 100% of stake
2. ✅ Lock funds in escrow for 30 days
3. ✅ Mark validator as BANNED in contract
4. ✅ Store evidence on-chain

**Delayed Action** (end of current epoch):
5. ⏰ Remove from validator set at next epoch boundary

### Why This Approach:

**Security**:
- ✅ Economic disincentive is **immediate** (100% slash + 30-day lock)
- ✅ Validator is **permanently banned** (can never rejoin)
- ✅ Evidence stored on-chain for auditing
- ✅ Relies on BFT fault tolerance (can handle up to ⌊(N-1)/3⌋ Byzantine validators)

**Stability**:
- ✅ Proven by 3+ major chains with billions in TVL
- ✅ Maintains consensus safety guarantees
- ✅ No risk of breaking quorum mid-epoch
- ✅ Simpler implementation (no consensus engine changes)

**Practical**:
- ✅ Lower development risk
- ✅ Easier to test and verify
- ✅ Standard approach in BFT systems

### Attack Window Consideration:

**Yes**, the slashed validator remains active until epoch ends, BUT:

1. **Financial incentive is gone** (already lost 100% of stake)
2. **Cannot withdraw** for 30 days (funds locked)
3. **Permanently banned** (no way to rejoin network)
4. **BFT fault tolerance** handles malicious validators (up to ⌊(N-1)/3⌋)
5. **Epoch ends soon** anyway (your epoch length determines this)

If your epochs are 100 blocks (~5 minutes), the extended window is minimal.

## Alternative: Force Epoch End (Hybrid Approach)

If you want to minimize the attack window further, we could implement:

**Trigger early epoch termination when slashing occurs**:
- Slash immediately ✅
- Force current epoch to end in next block ✅
- Remove validator at new epoch boundary ✅
- Attack window: **Only 1 block**

**Tradeoffs**:
- ✅ Short attack window (1 block vs full epoch)
- ✅ Maintains epoch boundary semantics
- ⚠️ Variable epoch lengths (breaks if tools depend on fixed length)
- ⚠️ Requires consensus runtime modifications
- ⚠️ No major chain does exactly this (unproven approach)

## Our Recommendation

**Start with the industry standard** (remove at natural epoch boundary):
- Lower risk
- Proven approach
- Simpler implementation
- Can always add forced epoch termination later if needed

The **economic disincentive is immediate** regardless of which approach you choose.

## Questions for You

1. **What is your typical epoch length** in blocks/time?
   - Longer epochs → stronger case for forced termination
   - Shorter epochs → natural boundary is fine

2. **How many validators** do you expect in production?
   - More validators → higher ⌊(N-1)/3⌋ Byzantine tolerance
   - Fewer validators → less tolerance for slashed validators remaining active

3. **Risk tolerance**:
   - Conservative → Follow industry standard (natural epoch boundary)
   - Aggressive → Implement forced epoch termination

Let us know your thoughts, and we'll proceed accordingly!

---

**Detailed research document**: See `DOUBLE_SIGNING_INDUSTRY_COMPARISON.md` for full analysis, sources, and technical details.

Best regards,
[Your Name]
