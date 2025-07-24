# Slashing









## Methods

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

### hydraChainContract

```solidity
function hydraChainContract() external view returns (address)
```






#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | address | undefined |

### initialize

```solidity
function initialize(address hydraChainAddr) external nonpayable
```





#### Parameters

| Name | Type | Description |
|---|---|---|
| hydraChainAddr | address | undefined |

### slashValidator

```solidity
function slashValidator(address validator, string reason) external nonpayable
```

Called by the system to slash a validator for double-signing.

*On-chain evidence verification is omitted; assumes consensus nodes have already verified.*

#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | Address of the validator to be slashed |
| reason | string | Reason for slashing (string) |



## Events

### Initialized

```solidity
event Initialized(uint8 version)
```





#### Parameters

| Name | Type | Description |
|---|---|---|
| version  | uint8 | undefined |

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

### InvalidValidatorAddress

```solidity
error InvalidValidatorAddress()
```






### Unauthorized

```solidity
error Unauthorized(string only)
```





#### Parameters

| Name | Type | Description |
|---|---|---|
| only | string | undefined |


