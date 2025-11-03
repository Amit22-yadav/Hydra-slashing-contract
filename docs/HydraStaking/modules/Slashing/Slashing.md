# Slashing



> Slashing

Validates double-signing evidence and manages slashed funds with 30-day lock period

*Implements BLS signature verification, rate limiting, and governance-controlled fund distribution*

## Methods

### LOCK_PERIOD

```solidity
function LOCK_PERIOD() external view returns (uint256)
```

Lock period before funds can be withdrawn (30 days in seconds)




#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | undefined |

### NATIVE_TOKEN_CONTRACT

```solidity
function NATIVE_TOKEN_CONTRACT() external view returns (address)
```






#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

### NATIVE_TRANSFER_PRECOMPILE

```solidity
function NATIVE_TRANSFER_PRECOMPILE() external view returns (address)
```






#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

### NATIVE_TRANSFER_PRECOMPILE_GAS

```solidity
function NATIVE_TRANSFER_PRECOMPILE_GAS() external view returns (uint256)
```






#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | undefined |

### PENALTY_PERCENTAGE

```solidity
function PENALTY_PERCENTAGE() external view returns (uint256)
```

Penalty is always 100% for double signing




#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | undefined |

### SYSTEM

```solidity
function SYSTEM() external view returns (address)
```






#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

### VALIDATOR_PKCHECK_PRECOMPILE

```solidity
function VALIDATOR_PKCHECK_PRECOMPILE() external view returns (address)
```






#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

### VALIDATOR_PKCHECK_PRECOMPILE_GAS

```solidity
function VALIDATOR_PKCHECK_PRECOMPILE_GAS() external view returns (uint256)
```






#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | undefined |

### batchBurnLockedFunds

```solidity
function batchBurnLockedFunds(address[] validators) external nonpayable
```

Burn locked funds for multiple validators



#### Parameters

| Name | Type | Description |
|---|---|---|
| validators | address[] | Array of validator addresses |

### batchSendToTreasury

```solidity
function batchSendToTreasury(address[] validators) external nonpayable
```

Send locked funds to treasury for multiple validators



#### Parameters

| Name | Type | Description |
|---|---|---|
| validators | address[] | Array of validator addresses |

### bls

```solidity
function bls() external view returns (contract IBLS)
```

BLS contract for signature verification




#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | contract IBLS | undefined |

### burnLockedFunds

```solidity
function burnLockedFunds(address validator) external nonpayable
```

Burn locked funds for a specific validator (send to address(0))

*Only callable by governance after lock period*

#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | Address of the slashed validator |

### daoTreasury

```solidity
function daoTreasury() external view returns (address)
```

DAO treasury address (optional destination for slashed funds)




#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

### getEvidenceHash

```solidity
function getEvidenceHash(address validator) external view returns (bytes32)
```

Get the evidence hash for a slashed validator



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | Address of the validator |

#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | bytes32 | The stored evidence hash |

### getPenaltyPercentage

```solidity
function getPenaltyPercentage() external pure returns (uint256)
```

Get current penalty percentage (always 100%)




#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | Penalty percentage in basis points (10000 = 100%) |

### getRemainingLockTime

```solidity
function getRemainingLockTime(address validator) external view returns (uint256)
```

Get remaining lock time for a validator&#39;s funds



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | Address of the validator |

#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | Seconds remaining until unlock (0 if already unlocked) |

### getSlashingsInCurrentBlock

```solidity
function getSlashingsInCurrentBlock() external view returns (uint256)
```

Get slashings count for current block




#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | Number of slashings in current block |

### getUnlockTime

```solidity
function getUnlockTime(address validator) external view returns (uint256)
```

Get unlock timestamp for a validator&#39;s locked funds



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | Address of the validator |

#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | Timestamp when funds can be withdrawn |

### governance

```solidity
function governance() external view returns (address)
```

Address that can withdraw funds after lock period (governance)




#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

### hasBeenSlashed

```solidity
function hasBeenSlashed(address validator) external view returns (bool)
```

Check if a validator has been slashed



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | Address of the validator |

#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | bool | True if the validator has been slashed |

### hydraChainContract

```solidity
function hydraChainContract() external view returns (address)
```

Reference to the HydraChain contract (Inspector module)




#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

### initialize

```solidity
function initialize(address hydraChainAddr, address governanceAddr, address daoTreasuryAddr, uint256 initialMaxSlashingsPerBlock) external nonpayable
```

Initializer for upgradeable pattern



#### Parameters

| Name | Type | Description |
|---|---|---|
| hydraChainAddr | address | Address of the HydraChain contract |
| governanceAddr | address | Address of governance (can withdraw after lock period) |
| daoTreasuryAddr | address | Address of DAO treasury (optional destination) |
| initialMaxSlashingsPerBlock | uint256 | Initial max slashings per block |

### isUnlocked

```solidity
function isUnlocked(address validator) external view returns (bool)
```

Check if funds are unlocked and ready for withdrawal



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | Address of the validator |

#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | bool | True if funds can be withdrawn |

### lockFunds

```solidity
function lockFunds(address validator) external payable
```

Lock slashed funds for a validator with 30-day lock period

*Called by Inspector contract during slashing*

#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | Address of the slashed validator |

### lockedFunds

```solidity
function lockedFunds(address) external view returns (uint256 amount, uint256 lockTimestamp, bool withdrawn)
```

Mapping of validator address to their locked slashed funds



#### Parameters

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

#### Returns

| Name | Type | Description |
|---|---|---|
| amount | uint256 | undefined |
| lockTimestamp | uint256 | undefined |
| withdrawn | bool | undefined |

### maxSlashingsPerBlock

```solidity
function maxSlashingsPerBlock() external view returns (uint256)
```

Maximum validators that can be slashed in a single block




#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | undefined |

### sendToTreasury

```solidity
function sendToTreasury(address validator) external nonpayable
```

Send locked funds to DAO treasury for a specific validator

*Only callable by governance after lock period*

#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | Address of the slashed validator |

### setBLSAddress

```solidity
function setBLSAddress(address blsAddr) external nonpayable
```

Set or update BLS contract address



#### Parameters

| Name | Type | Description |
|---|---|---|
| blsAddr | address | Address of the BLS contract |

### setDaoTreasury

```solidity
function setDaoTreasury(address newTreasury) external nonpayable
```

Update DAO treasury address



#### Parameters

| Name | Type | Description |
|---|---|---|
| newTreasury | address | New DAO treasury address |

### setGovernance

```solidity
function setGovernance(address newGovernance) external nonpayable
```

Update governance address



#### Parameters

| Name | Type | Description |
|---|---|---|
| newGovernance | address | New governance address |

### setMaxSlashingsPerBlock

```solidity
function setMaxSlashingsPerBlock(uint256 newMax) external nonpayable
```

Update the maximum slashings allowed per block

*Protection against mass slashing events due to bugs*

#### Parameters

| Name | Type | Description |
|---|---|---|
| newMax | uint256 | New maximum slashings per block |

### slashValidator

```solidity
function slashValidator(address validator, IBFTMessage msg1, IBFTMessage msg2, string reason) external nonpayable
```





#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | undefined |
| msg1 | IBFTMessage | undefined |
| msg2 | IBFTMessage | undefined |
| reason | string | undefined |

### slashingEvidenceHash

```solidity
function slashingEvidenceHash(address) external view returns (bytes32)
```

Mapping to store evidence hash for each slashed validator (for auditing)



#### Parameters

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | bytes32 | undefined |

### slashingsInBlock

```solidity
function slashingsInBlock(uint256) external view returns (uint256)
```

Tracks slashings per block for protection



#### Parameters

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | undefined |

#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | undefined |



## Events

### DaoTreasuryUpdated

```solidity
event DaoTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury)
```

Emitted when DAO treasury address is updated



#### Parameters

| Name | Type | Description |
|---|---|---|
| oldTreasury `indexed` | address | undefined |
| newTreasury `indexed` | address | undefined |

### DoubleSignEvidence

```solidity
event DoubleSignEvidence(address indexed validator, bytes32 evidenceHash, uint64 height, uint64 round, bytes32 msg1Hash, bytes32 msg2Hash)
```

Emitted when double-signing evidence is validated and stored



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator `indexed` | address | undefined |
| evidenceHash  | bytes32 | undefined |
| height  | uint64 | undefined |
| round  | uint64 | undefined |
| msg1Hash  | bytes32 | undefined |
| msg2Hash  | bytes32 | undefined |

### FundsBurned

```solidity
event FundsBurned(address indexed validator, uint256 amount, address indexed burnedBy)
```

Emitted when governance burns locked funds



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator `indexed` | address | undefined |
| amount  | uint256 | undefined |
| burnedBy `indexed` | address | undefined |

### FundsLocked

```solidity
event FundsLocked(address indexed validator, uint256 amount, uint256 unlockTime)
```

Emitted when funds are locked in escrow



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator `indexed` | address | undefined |
| amount  | uint256 | undefined |
| unlockTime  | uint256 | undefined |

### FundsSentToTreasury

```solidity
event FundsSentToTreasury(address indexed validator, uint256 amount, address indexed treasury)
```

Emitted when governance sends funds to DAO treasury



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator `indexed` | address | undefined |
| amount  | uint256 | undefined |
| treasury `indexed` | address | undefined |

### GovernanceUpdated

```solidity
event GovernanceUpdated(address indexed oldGovernance, address indexed newGovernance)
```

Emitted when governance address is updated



#### Parameters

| Name | Type | Description |
|---|---|---|
| oldGovernance `indexed` | address | undefined |
| newGovernance `indexed` | address | undefined |

### Initialized

```solidity
event Initialized(uint8 version)
```





#### Parameters

| Name | Type | Description |
|---|---|---|
| version  | uint8 | undefined |

### MaxSlashingsPerBlockUpdated

```solidity
event MaxSlashingsPerBlockUpdated(uint256 oldMax, uint256 newMax)
```

Emitted when max slashings per block is updated



#### Parameters

| Name | Type | Description |
|---|---|---|
| oldMax  | uint256 | undefined |
| newMax  | uint256 | undefined |

### ValidatorSlashed

```solidity
event ValidatorSlashed(address indexed validator, string reason)
```

Emitted when a validator is slashed



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator `indexed` | address | undefined |
| reason  | string | undefined |



## Errors

### AlreadyWithdrawn

```solidity
error AlreadyWithdrawn()
```






### BLSNotSet

```solidity
error BLSNotSet()
```






### EvidenceMismatch

```solidity
error EvidenceMismatch(string detail)
```





#### Parameters

| Name | Type | Description |
|---|---|---|
| detail | string | undefined |

### FundsStillLocked

```solidity
error FundsStillLocked(uint256 unlockTime)
```





#### Parameters

| Name | Type | Description |
|---|---|---|
| unlockTime | uint256 | undefined |

### InvalidAddress

```solidity
error InvalidAddress()
```






### InvalidValidatorAddress

```solidity
error InvalidValidatorAddress()
```






### MaxSlashingsExceeded

```solidity
error MaxSlashingsExceeded()
```






### NoLockedFunds

```solidity
error NoLockedFunds()
```






### OnlyGovernance

```solidity
error OnlyGovernance()
```






### TransferFailed

```solidity
error TransferFailed()
```






### Unauthorized

```solidity
error Unauthorized(string only)
```





#### Parameters

| Name | Type | Description |
|---|---|---|
| only | string | undefined |

### ValidatorAlreadySlashed

```solidity
error ValidatorAlreadySlashed()
```







