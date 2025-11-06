# ISlashing









## Methods

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



## Events

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



