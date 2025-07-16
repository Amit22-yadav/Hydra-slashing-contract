# ISlashing









## Methods

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



