## Architecture

### Core Components

#### 1. WeeklyRewardsModule Contract
```solidity
contract WeeklyRewardsModule {
    // Configuration
    mapping(uint256 => bool) public authorizedTokenIds;
    uint256 public wellRetentionBps;  // Basis points (e.g., 1000 = 10%)
    uint256 public btcRetentionBps;
    uint256 public callerRewardBps;
    uint256 public lastExecutionTime;
    uint256 public constant EXECUTION_INTERVAL = 7 days;
    
    // Contract addresses
    address public immutable burnAndEarn;
    address public immutable multiRewards;
    address public immutable wellToken;
    address public immutable btcToken;
    address public immutable safe;
}
```

#### 2. Execution Flow (Updated)

```mermaid
sequenceDiagram
    participant Caller
    participant Module as WeeklyRewardsModule
    participant Safe as Safe Multisig
    participant BurnAndEarn
    participant MultiRewards
    participant WELL as WELL Token
    participant BTC as BTC Token

    Note over Caller,BTC: Prerequisites: Safe has approved Module for token spending

    Caller->>Module: executeWeeklyRewards()
    
    Note over Module: Check weekly cooldown
    
    Module->>Safe: execTransactionFromModule(BurnAndEarn.earn)
    Safe->>BurnAndEarn: earn(tokenIds)
    BurnAndEarn->>WELL: transfer(safe, wellAmount)
    BurnAndEarn->>BTC: transfer(safe, btcAmount)
    
    Note over Module: Calculate retention amounts
    Module->>WELL: balanceOf(safe)
    Module->>BTC: balanceOf(safe)
    
    Note over Module: Retain configured percentage in Safe
    Note over Module: Calculate amounts for rewards distribution
    
    Module->>Safe: execTransactionFromModule(MultiRewards.setRewardsDuration)
    Safe->>MultiRewards: setRewardsDuration(WELL, 7 days)
    
    Module->>Safe: execTransactionFromModule(MultiRewards.setRewardsDuration)
    Safe->>MultiRewards: setRewardsDuration(BTC, 7 days)
    
    Module->>Safe: execTransactionFromModule(WELL.approve)
    Safe->>WELL: approve(MultiRewards, distributionAmount)
    
    Module->>Safe: execTransactionFromModule(BTC.approve)
    Safe->>BTC: approve(MultiRewards, distributionAmount)
    
    Module->>Safe: execTransactionFromModule(MultiRewards.notifyRewardAmount)
    Safe->>MultiRewards: notifyRewardAmount(WELL, distributionAmount)
    MultiRewards->>WELL: transferFrom(safe, multiRewards, distributionAmount)
    
    Module->>Safe: execTransactionFromModule(MultiRewards.notifyRewardAmount)
    Safe->>MultiRewards: notifyRewardAmount(BTC, distributionAmount)
    MultiRewards->>BTC: transferFrom(safe, multiRewards, distributionAmount)
    
    Module->>Safe: execTransactionFromModule(WELL.transfer)
    Safe->>WELL: transfer(caller, callerReward)
    
    Note over Module: Update lastExecutionTime
```

#### 3. Key Functions

##### Main Execution Function
```solidity
function executeWeeklyRewards() external {
    require(block.timestamp >= lastExecutionTime + EXECUTION_INTERVAL, "Too early");
    
    // 1. Collect LP fees
    _collectLPFees();
    
    // 2. Calculate token balances and retention
    (uint256 wellDistribution, uint256 btcDistribution, uint256 callerReward) = _calculateDistributions();
    
    // 3. Set rewards duration
    _setRewardsDuration();
    
    // 4. Approve and notify reward amounts
    _distributeRewards(wellDistribution, btcDistribution);
    
    // 5. Reward caller
    _rewardCaller(callerReward);
    
    lastExecutionTime = block.timestamp;
}
```

##### Token Distribution Logic (Updated)
```solidity
function _calculateDistributions() internal view returns (uint256 wellDist, uint256 btcDist, uint256 callerReward) {
    uint256 wellBalance = IERC20(wellToken).balanceOf(safe);
    uint256 btcBalance = IERC20(btcToken).balanceOf(safe);
    
    // Calculate retention amounts (stay in Safe)
    uint256 wellRetention = (wellBalance * wellRetentionBps) / 10000;
    uint256 btcRetention = (btcBalance * btcRetentionBps) / 10000;
    
    // Calculate distribution amounts (go to MultiRewards)
    wellDist = wellBalance - wellRetention;
    btcDist = btcBalance - btcRetention;
    
    // Calculate caller reward from WELL distribution
    callerReward = (wellDist * callerRewardBps) / 10000;
    wellDist -= callerReward;
}
```

##### Approval and Distribution (New)
```solidity
function _distributeRewards(uint256 wellAmount, uint256 btcAmount) internal {
    // Approve MultiRewards to spend tokens
    bytes memory approveWellData = abi.encodeWithSelector(
        IERC20.approve.selector, 
        multiRewards, 
        wellAmount
    );
    require(ISafe(safe).execTransactionFromModule(wellToken, 0, approveWellData, Enum.Operation.Call));
    
    bytes memory approveBtcData = abi.encodeWithSelector(
        IERC20.approve.selector, 
        multiRewards, 
        btcAmount
    );
    require(ISafe(safe).execTransactionFromModule(btcToken, 0, approveBtcData, Enum.Operation.Call));
    
    // Notify reward amounts (this will transfer tokens)
    bytes memory notifyWellData = abi.encodeWithSelector(
        IMultiRewards.notifyRewardAmount.selector,
        wellToken,
        wellAmount
    );
    require(ISafe(safe).execTransactionFromModule(multiRewards, 0, notifyWellData, Enum.Operation.Call));
    
    bytes memory notifyBtcData = abi.encodeWithSelector(
        IMultiRewards.notifyRewardAmount.selector,
        btcToken,
        btcAmount
    );
    require(ISafe(safe).execTransactionFromModule(multiRewards, 0, notifyBtcData, Enum.Operation.Call));
}
```

#### 4. Configuration Management

##### Owner-Only Configuration Functions
```solidity
function setTokenId(uint256 tokenId, bool authorized) external {
    require(ISafe(safe).isOwner(msg.sender), "Only Safe owners");
    authorizedTokenIds[tokenId] = authorized;
}

function setRetentionPercentages(uint256 _wellRetentionBps, uint256 _btcRetentionBps) external {
    require(ISafe(safe).isOwner(msg.sender), "Only Safe owners");
    require(_wellRetentionBps <= 10000 && _btcRetentionBps <= 10000, "Invalid percentages");
    wellRetentionBps = _wellRetentionBps;
    btcRetentionBps = _btcRetentionBps;
}

function setCallerRewardPercentage(uint256 _callerRewardBps) external {
    require(ISafe(safe).isOwner(msg.sender), "Only Safe owners");
    require(_callerRewardBps <= 1000, "Max 10% caller reward");
    callerRewardBps = _callerRewardBps;
}
```

## Implementation Phases

### Phase 1: Core Module Structure
- [ ] Basic Safe module setup with proper inheritance
- [ ] Weekly cooldown mechanism
- [ ] Access control for configuration functions
- [ ] Event definitions

### Phase 2: Configuration System
- [ ] Token ID management functions
- [ ] Retention percentage configuration
- [ ] Caller reward configuration
- [ ] Parameter validation

### Phase 3: LP Fee Collection
- [ ] Integration with BurnAndEarn contract
- [ ] Token ID iteration and fee collection
- [ ] Error handling for failed collections

### Phase 4: Token Distribution Logic
- [ ] Balance calculation functions
- [ ] Retention amount calculations
- [ ] Distribution amount calculations
- [ ] Caller reward calculations

### Phase 5: MultiRewards Integration
- [ ] Rewards duration setting
- [ ] Token approval mechanism
- [ ] Reward amount notification
- [ ] Proper error handling

### Phase 6: Security & Testing
- [ ] Reentrancy protection
- [ ] Input validation
- [ ] Comprehensive unit tests
- [ ] Integration tests with Safe

### Phase 7: Deployment & Documentation
- [ ] Deployment scripts
- [ ] Safe module installation guide
- [ ] Usage documentation
- [ ] Emergency procedures

## Security Considerations

### Access Control
- Only Safe owners can modify configuration
- Anyone can trigger weekly execution (with cooldown)
- Module must be properly enabled on Safe

### Token Safety
- **Critical**: Retention happens BEFORE `notifyRewardAmount` calls
- **Critical**: Proper approval flow before token transfers
- Validation of retention percentages (≤100%)
- Protection against token drainage

### Execution Safety
- Weekly cooldown prevents spam
- Atomic execution of all steps
- Proper error handling and reversion
- Reentrancy protection

## Key Changes from Original Plan

1. **Token Retention Timing**: Now happens BEFORE calling `notifyRewardAmount` instead of after
2. **Approval Flow**: Added explicit approval steps before `notifyRewardAmount` calls
3. **Distribution Calculation**: Updated to account for the fact that `notifyRewardAmount` transfers tokens away
4. **Execution Order**: Restructured to ensure tokens are retained before any transfers occur

## Dependencies

- Safe Smart Account contracts
- BurnAndEarn contract interface
- MultiRewards contract interface
- OpenZeppelin SafeERC20 library
- Solidity 0.8.28 compatibility

### Testing Strategy

#### Unit Tests
- Test each internal function in isolation
- Mock external contract calls
- Validate calculation logic
- Test access control mechanisms

#### Integration Tests
- Test with actual [`BurnAndEarn`](src/BurnAndEarn.sol) and [`MultiRewards`](src/MultiRewards.sol) contracts
- Verify token flow end-to-end
- Test Safe module integration
- Validate weekly cooldown mechanism

#### Security Tests
- Test reentrancy protection
- Validate access control
- Test edge cases (zero balances, failed calls)
- Test with malicious token contracts

This updated plan addresses the critical token flow requirements and ensures proper handling of approvals and retention percentages.