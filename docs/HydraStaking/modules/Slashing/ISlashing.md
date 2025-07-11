# ISlashing









## Methods

### getSlashedAmount

```solidity
function getSlashedAmount(address validator) external view returns (uint256)
```

Returns the slashed amount for a validator



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | The address of the validator |

#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | uint256 | The total amount slashed |

### isSlashed

```solidity
function isSlashed(address validator) external view returns (bool)
```

Returns whether a validator is slashed



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | The address of the validator |

#### Returns

| Name | Type | Description |
|---|---|---|
| _0 | bool | True if the validator is slashed |

### slashValidator

```solidity
function slashValidator(address validator, string reason) external nonpayable
```

Slashes a validator&#39;s stake for misbehavior



#### Parameters

| Name | Type | Description |
|---|---|---|
| validator | address | The address of the validator to slash |
| reason | string | The reason for slashing |



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



