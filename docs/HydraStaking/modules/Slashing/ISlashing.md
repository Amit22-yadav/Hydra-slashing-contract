# ISlashing









## Methods

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



