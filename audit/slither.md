**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [arbitrary-send-eth](#arbitrary-send-eth) (2 results) (High)
 - [unprotected-upgrade](#unprotected-upgrade) (1 results) (High)
 - [incorrect-equality](#incorrect-equality) (3 results) (Medium)
 - [unused-return](#unused-return) (18 results) (Medium)
 - [reentrancy-benign](#reentrancy-benign) (1 results) (Low)
 - [reentrancy-events](#reentrancy-events) (5 results) (Low)
 - [timestamp](#timestamp) (1 results) (Low)
 - [assembly](#assembly) (66 results) (Informational)
 - [pragma](#pragma) (5 results) (Informational)
 - [dead-code](#dead-code) (22 results) (Informational)
 - [solc-version](#solc-version) (10 results) (Informational)
 - [low-level-calls](#low-level-calls) (20 results) (Informational)
 - [naming-convention](#naming-convention) (34 results) (Informational)
 - [reentrancy-unlimited-gas](#reentrancy-unlimited-gas) (2 results) (Informational)
 - [unused-import](#unused-import) (2 results) (Informational)
 - [divide-before-multiply](#divide-before-multiply) (2 results) (Medium)
 - [unchecked-transfer](#unchecked-transfer) (1 results) (High)
## arbitrary-send-eth
Impact: High
Confidence: Medium
 - [ ] ID-0
[BaseStrategy.recoverETH(address)](src/BaseStrategy.sol#L61-L67) sends eth to arbitrary user
	Dangerous calls:
	- [to.transfer(amount)](src/BaseStrategy.sol#L64)

src/BaseStrategy.sol#L61-L67


 - [ ] ID-1
[BaseStrategy.recoverETH(address)](src/BaseStrategy.sol#L61-L67) sends eth to arbitrary user
	Dangerous calls:
	- [to.transfer(amount)](src/BaseStrategy.sol#L64)

src/BaseStrategy.sol#L61-L67


## unprotected-upgrade
Impact: High
Confidence: High
 - [ ] ID-2
[ERC20MoonwellMorphoStrategy](src/ERC20MoonwellMorphoStrategy.sol#L22-L360) is an upgradeable contract that does not protect its initialize functions: [ERC20MoonwellMorphoStrategy.initialize(ERC20MoonwellMorphoStrategy.InitParams)](src/ERC20MoonwellMorphoStrategy.sol#L106-L129). Anyone can delete the contract with: [UUPSUpgradeable.upgradeToAndCall(address,bytes)](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L92-L95)
src/ERC20MoonwellMorphoStrategy.sol#L22-L360


## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-3
[ERC20MoonwellMorphoStrategy.updatePosition(uint256,uint256)](src/ERC20MoonwellMorphoStrategy.sol#L226-L252) uses a dangerous strict equality:
	- [require(bool,string)(mToken.redeem(mTokenBalance) == 0,Failed to redeem mToken)](src/ERC20MoonwellMorphoStrategy.sol#L232)

src/ERC20MoonwellMorphoStrategy.sol#L226-L252


 - [ ] ID-4
[ERC20MoonwellMorphoStrategy.depositInternal(uint256)](src/ERC20MoonwellMorphoStrategy.sol#L340-L359) uses a dangerous strict equality:
	- [require(bool,string)(mToken.mint(targetMoonwell) == 0,MToken mint failed)](src/ERC20MoonwellMorphoStrategy.sol#L350)

src/ERC20MoonwellMorphoStrategy.sol#L340-L359


 - [ ] ID-5
[ERC20MoonwellMorphoStrategy.withdraw(uint256)](src/ERC20MoonwellMorphoStrategy.sol#L182-L216) uses a dangerous strict equality:
	- [require(bool,string)(mToken.redeemUnderlying(withdrawFromMoonwell) == 0,Failed to redeem mToken)](src/ERC20MoonwellMorphoStrategy.sol#L198)

src/ERC20MoonwellMorphoStrategy.sol#L182-L216


## unused-return
Impact: Medium
Confidence: Medium
 - [ ] ID-6
[ERC1967Utils.upgradeBeaconToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166) ignores return value by [Address.functionDelegateCall(IBeacon(newBeacon).implementation(),data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L162)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166


 - [ ] ID-7
[ERC20MoonwellMorphoStrategy.withdraw(uint256)](src/ERC20MoonwellMorphoStrategy.sol#L182-L216) ignores return value by [metaMorphoVault.withdraw(withdrawFromMetaMorpho,address(this),address(this))](src/ERC20MoonwellMorphoStrategy.sol#L205)

src/ERC20MoonwellMorphoStrategy.sol#L182-L216


 - [ ] ID-8
[ERC1967Utils.upgradeToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76) ignores return value by [Address.functionDelegateCall(newImplementation,data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L72)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76


 - [ ] ID-9
[ERC20MoonwellMorphoStrategy.depositInternal(uint256)](src/ERC20MoonwellMorphoStrategy.sol#L340-L359) ignores return value by [metaMorphoVault.deposit(targetMetaMorpho,address(this))](src/ERC20MoonwellMorphoStrategy.sol#L357)

src/ERC20MoonwellMorphoStrategy.sol#L340-L359


 - [ ] ID-10
[ERC20MoonwellMorphoStrategy.updatePosition(uint256,uint256)](src/ERC20MoonwellMorphoStrategy.sol#L226-L252) ignores return value by [metaMorphoVault.redeem(vaultBalance,address(this),address(this))](src/ERC20MoonwellMorphoStrategy.sol#L238)

src/ERC20MoonwellMorphoStrategy.sol#L226-L252


 - [ ] ID-11
[ERC20MoonwellMorphoStrategy.depositInternal(uint256)](src/ERC20MoonwellMorphoStrategy.sol#L340-L359) ignores return value by [token.approve(address(mToken),targetMoonwell)](src/ERC20MoonwellMorphoStrategy.sol#L347)

src/ERC20MoonwellMorphoStrategy.sol#L340-L359


 - [ ] ID-12
[ERC20MoonwellMorphoStrategy.depositInternal(uint256)](src/ERC20MoonwellMorphoStrategy.sol#L340-L359) ignores return value by [token.approve(address(metaMorphoVault),targetMetaMorpho)](src/ERC20MoonwellMorphoStrategy.sol#L354)

src/ERC20MoonwellMorphoStrategy.sol#L340-L359


 - [ ] ID-13
[ERC1967Utils.upgradeBeaconToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166) ignores return value by [Address.functionDelegateCall(IBeacon(newBeacon).implementation(),data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L162)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166


 - [ ] ID-14
[ERC1967Utils.upgradeToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76) ignores return value by [Address.functionDelegateCall(newImplementation,data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L72)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76


 - [ ] ID-15
[ERC1967Utils.upgradeBeaconToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166) ignores return value by [Address.functionDelegateCall(IBeacon(newBeacon).implementation(),data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L162)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166


 - [ ] ID-16
[ERC1967Utils.upgradeToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76) ignores return value by [Address.functionDelegateCall(newImplementation,data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L72)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76


 - [ ] ID-17
[ERC1967Utils.upgradeBeaconToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166) ignores return value by [Address.functionDelegateCall(IBeacon(newBeacon).implementation(),data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L162)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166


 - [ ] ID-18
[ERC1967Utils.upgradeToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76) ignores return value by [Address.functionDelegateCall(newImplementation,data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L72)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76


 - [ ] ID-19
[AccessControlEnumerable._grantRole(bytes32,address)](lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol#L64-L70) ignores return value by [_roleMembers[role].add(account)](lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol#L67)

lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol#L64-L70


 - [ ] ID-20
[MamoStrategyRegistry.addStrategy(address,address)](src/MamoStrategyRegistry.sol#L169-L191) ignores return value by [_userStrategies[user].add(strategy)](src/MamoStrategyRegistry.sol#L188)

src/MamoStrategyRegistry.sol#L169-L191


 - [ ] ID-21
[ERC1967Utils.upgradeBeaconToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166) ignores return value by [Address.functionDelegateCall(IBeacon(newBeacon).implementation(),data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L162)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166


 - [ ] ID-22
[AccessControlEnumerable._revokeRole(bytes32,address)](lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol#L75-L81) ignores return value by [_roleMembers[role].remove(account)](lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol#L78)

lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol#L75-L81


 - [ ] ID-23
[ERC1967Utils.upgradeToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76) ignores return value by [Address.functionDelegateCall(newImplementation,data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L72)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76


## reentrancy-benign
Impact: Low
Confidence: Medium
 - [ ] ID-24
Reentrancy in [ERC20MoonwellMorphoStrategy.updatePosition(uint256,uint256)](src/ERC20MoonwellMorphoStrategy.sol#L226-L252):
	External calls:
	- [require(bool,string)(mToken.redeem(mTokenBalance) == 0,Failed to redeem mToken)](src/ERC20MoonwellMorphoStrategy.sol#L232)
	- [metaMorphoVault.redeem(vaultBalance,address(this),address(this))](src/ERC20MoonwellMorphoStrategy.sol#L238)
	State variables written after the call(s):
	- [splitMToken = splitA](src/ERC20MoonwellMorphoStrategy.sol#L245)
	- [splitVault = splitB](src/ERC20MoonwellMorphoStrategy.sol#L246)

src/ERC20MoonwellMorphoStrategy.sol#L226-L252


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-25
Reentrancy in [ERC20MoonwellMorphoStrategy.depositIdleTokens()](src/ERC20MoonwellMorphoStrategy.sol#L259-L269):
	External calls:
	- [depositInternal(tokenBalance)](src/ERC20MoonwellMorphoStrategy.sol#L264)
		- [token.approve(address(mToken),targetMoonwell)](src/ERC20MoonwellMorphoStrategy.sol#L347)
		- [require(bool,string)(mToken.mint(targetMoonwell) == 0,MToken mint failed)](src/ERC20MoonwellMorphoStrategy.sol#L350)
		- [token.approve(address(metaMorphoVault),targetMetaMorpho)](src/ERC20MoonwellMorphoStrategy.sol#L354)
		- [metaMorphoVault.deposit(targetMetaMorpho,address(this))](src/ERC20MoonwellMorphoStrategy.sol#L357)
	Event emitted after the call(s):
	- [Deposit(address(token),tokenBalance)](src/ERC20MoonwellMorphoStrategy.sol#L266)

src/ERC20MoonwellMorphoStrategy.sol#L259-L269


 - [ ] ID-26
Reentrancy in [ERC20MoonwellMorphoStrategy.updatePosition(uint256,uint256)](src/ERC20MoonwellMorphoStrategy.sol#L226-L252):
	External calls:
	- [require(bool,string)(mToken.redeem(mTokenBalance) == 0,Failed to redeem mToken)](src/ERC20MoonwellMorphoStrategy.sol#L232)
	- [metaMorphoVault.redeem(vaultBalance,address(this),address(this))](src/ERC20MoonwellMorphoStrategy.sol#L238)
	- [depositInternal(totalTokenBalance)](src/ERC20MoonwellMorphoStrategy.sol#L249)
		- [token.approve(address(mToken),targetMoonwell)](src/ERC20MoonwellMorphoStrategy.sol#L347)
		- [require(bool,string)(mToken.mint(targetMoonwell) == 0,MToken mint failed)](src/ERC20MoonwellMorphoStrategy.sol#L350)
		- [token.approve(address(metaMorphoVault),targetMetaMorpho)](src/ERC20MoonwellMorphoStrategy.sol#L354)
		- [metaMorphoVault.deposit(targetMetaMorpho,address(this))](src/ERC20MoonwellMorphoStrategy.sol#L357)
	Event emitted after the call(s):
	- [PositionUpdated(splitA,splitB)](src/ERC20MoonwellMorphoStrategy.sol#L251)

src/ERC20MoonwellMorphoStrategy.sol#L226-L252


 - [ ] ID-27
Reentrancy in [ERC20MoonwellMorphoStrategy.withdraw(uint256)](src/ERC20MoonwellMorphoStrategy.sol#L182-L216):
	External calls:
	- [require(bool,string)(getTotalBalance() > amount,Withdrawal amount exceeds available balance in strategy)](src/ERC20MoonwellMorphoStrategy.sol#L185)
		- [vaultBalance + mToken.balanceOfUnderlying(address(this)) + token.balanceOf(address(this))](src/ERC20MoonwellMorphoStrategy.sol#L282)
	- [require(bool,string)(mToken.redeemUnderlying(withdrawFromMoonwell) == 0,Failed to redeem mToken)](src/ERC20MoonwellMorphoStrategy.sol#L198)
	- [metaMorphoVault.withdraw(withdrawFromMetaMorpho,address(this),address(this))](src/ERC20MoonwellMorphoStrategy.sol#L205)
	Event emitted after the call(s):
	- [Withdraw(address(token),amount)](src/ERC20MoonwellMorphoStrategy.sol#L215)

src/ERC20MoonwellMorphoStrategy.sol#L182-L216


 - [ ] ID-28
Reentrancy in [ERC20MoonwellMorphoStrategy.deposit(uint256)](src/ERC20MoonwellMorphoStrategy.sol#L138-L148):
	External calls:
	- [depositInternal(amount)](src/ERC20MoonwellMorphoStrategy.sol#L145)
		- [token.approve(address(mToken),targetMoonwell)](src/ERC20MoonwellMorphoStrategy.sol#L347)
		- [require(bool,string)(mToken.mint(targetMoonwell) == 0,MToken mint failed)](src/ERC20MoonwellMorphoStrategy.sol#L350)
		- [token.approve(address(metaMorphoVault),targetMetaMorpho)](src/ERC20MoonwellMorphoStrategy.sol#L354)
		- [metaMorphoVault.deposit(targetMetaMorpho,address(this))](src/ERC20MoonwellMorphoStrategy.sol#L357)
	Event emitted after the call(s):
	- [Deposit(address(token),amount)](src/ERC20MoonwellMorphoStrategy.sol#L147)

src/ERC20MoonwellMorphoStrategy.sol#L138-L148


 - [ ] ID-29
Reentrancy in [MamoStrategyRegistry.upgradeStrategy(address)](src/MamoStrategyRegistry.sol#L86-L110):
	External calls:
	- [IUUPSUpgradeable(strategy).upgradeToAndCall(latestImplementation,new bytes(0))](src/MamoStrategyRegistry.sol#L107)
	Event emitted after the call(s):
	- [StrategyImplementationUpdated(strategy,oldImplementation,latestImplementation)](src/MamoStrategyRegistry.sol#L109)

src/MamoStrategyRegistry.sol#L86-L110


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-30
[ERC20MoonwellMorphoStrategy.isValidSignature(bytes32,bytes)](src/ERC20MoonwellMorphoStrategy.sol#L287-L332) uses timestamp for comparisons
	Dangerous comparisons:
	- [require(bool,string)(_order.validTo >= block.timestamp + 300,Order expires too soon - must be valid for at least 5 minutes)](src/ERC20MoonwellMorphoStrategy.sol#L294-L297)
	- [require(bool,string)(_order.validTo <= block.timestamp + slippagePriceChecker.maxTimePriceValid(address(_order.sellToken)),Order expires too far in the future)](src/ERC20MoonwellMorphoStrategy.sol#L299-L302)

src/ERC20MoonwellMorphoStrategy.sol#L287-L332


## assembly
Impact: Informational
Confidence: High
 - [ ] ID-31
[SafeERC20._callOptionalReturn(IERC20,bytes)](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L159-L177) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L162-L172)

lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L159-L177


 - [ ] ID-32
[StorageSlot.getAddressSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L67-L69)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70


 - [ ] ID-33
[GPv2Order.extractOrderUidParams(bytes)](src/libraries/GPv2Order.sol#L212-L226) uses assembly
	- [INLINE ASM](src/libraries/GPv2Order.sol#L221-L225)

src/libraries/GPv2Order.sol#L212-L226


 - [ ] ID-34
[StorageSlot.getInt256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L103-L105)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106


 - [ ] ID-35
[StorageSlot.getBytesSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L130-L132)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133


 - [ ] ID-36
[StorageSlot.getStringSlot(string)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L121-L123)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124


 - [ ] ID-37
[StorageSlot.getBytes32Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L85-L87)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88


 - [ ] ID-38
[StorageSlot.getBytesSlot(bytes)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L139-L141)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142


 - [ ] ID-39
[Initializable._getInitializableStorage()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L223-L227) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L224-L226)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L223-L227


 - [ ] ID-40
[Address._revert(bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/Address.sol#L142-L145)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149


 - [ ] ID-41
[StorageSlot.getBooleanSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L76-L78)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79


 - [ ] ID-42
[GPv2Order.hash(GPv2Order.Data,bytes32)](src/libraries/GPv2Order.sol#L124-L153) uses assembly
	- [INLINE ASM](src/libraries/GPv2Order.sol#L132-L138)
	- [INLINE ASM](src/libraries/GPv2Order.sol#L146-L152)

src/libraries/GPv2Order.sol#L124-L153


 - [ ] ID-43
[StorageSlot.getStringSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L112-L114)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115


 - [ ] ID-44
[GPv2Order.packOrderUidParams(bytes,bytes32,address,uint32)](src/libraries/GPv2Order.sol#L166-L198) uses assembly
	- [INLINE ASM](src/libraries/GPv2Order.sol#L193-L197)

src/libraries/GPv2Order.sol#L166-L198


 - [ ] ID-45
[SafeERC20._callOptionalReturnBool(IERC20,bytes)](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L187-L197) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L191-L195)

lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L187-L197


 - [ ] ID-46
[StorageSlot.getUint256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L94-L96)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97


 - [ ] ID-47
[StorageSlot.getAddressSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L67-L69)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70


 - [ ] ID-48
[StorageSlot.getInt256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L103-L105)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106


 - [ ] ID-49
[OwnableUpgradeable._getOwnableStorage()](lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L30-L34) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L31-L33)

lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L30-L34


 - [ ] ID-50
[StorageSlot.getBytesSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L130-L132)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133


 - [ ] ID-51
[StorageSlot.getStringSlot(string)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L121-L123)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124


 - [ ] ID-52
[StorageSlot.getBytes32Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L85-L87)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88


 - [ ] ID-53
[StorageSlot.getBytesSlot(bytes)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L139-L141)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142


 - [ ] ID-54
[Initializable._getInitializableStorage()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L223-L227) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L224-L226)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L223-L227


 - [ ] ID-55
[Address._revert(bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/Address.sol#L142-L145)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149


 - [ ] ID-56
[StorageSlot.getBooleanSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L76-L78)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79


 - [ ] ID-57
[StorageSlot.getStringSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L112-L114)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115


 - [ ] ID-58
[StorageSlot.getUint256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L94-L96)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97


 - [ ] ID-59
[SafeERC20._callOptionalReturn(IERC20,bytes)](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L159-L177) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L162-L172)

lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L159-L177


 - [ ] ID-60
[StorageSlot.getAddressSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L67-L69)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70


 - [ ] ID-61
[StorageSlot.getInt256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L103-L105)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106


 - [ ] ID-62
[StorageSlot.getBytesSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L130-L132)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133


 - [ ] ID-63
[StorageSlot.getStringSlot(string)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L121-L123)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124


 - [ ] ID-64
[StorageSlot.getBytes32Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L85-L87)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88


 - [ ] ID-65
[StorageSlot.getBytesSlot(bytes)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L139-L141)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142


 - [ ] ID-66
[Initializable._getInitializableStorage()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L223-L227) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L224-L226)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L223-L227


 - [ ] ID-67
[Address._revert(bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/Address.sol#L142-L145)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149


 - [ ] ID-68
[StorageSlot.getBooleanSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L76-L78)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79


 - [ ] ID-69
[StorageSlot.getStringSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L112-L114)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115


 - [ ] ID-70
[SafeERC20._callOptionalReturnBool(IERC20,bytes)](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L187-L197) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L191-L195)

lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L187-L197


 - [ ] ID-71
[StorageSlot.getUint256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L94-L96)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97


 - [ ] ID-72
[StorageSlot.getAddressSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L67-L69)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70


 - [ ] ID-73
[Proxy._delegate(address)](lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L22-L45) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L23-L44)

lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L22-L45


 - [ ] ID-74
[StorageSlot.getInt256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L103-L105)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106


 - [ ] ID-75
[StorageSlot.getBytesSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L130-L132)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133


 - [ ] ID-76
[StorageSlot.getStringSlot(string)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L121-L123)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124


 - [ ] ID-77
[StorageSlot.getBytes32Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L85-L87)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88


 - [ ] ID-78
[StorageSlot.getBytesSlot(bytes)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L139-L141)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142


 - [ ] ID-79
[Address._revert(bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/Address.sol#L142-L145)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149


 - [ ] ID-80
[StorageSlot.getBooleanSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L76-L78)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79


 - [ ] ID-81
[StorageSlot.getStringSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L112-L114)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115


 - [ ] ID-82
[StorageSlot.getUint256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L94-L96)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97


 - [ ] ID-83
[StorageSlot.getAddressSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L67-L69)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L66-L70


 - [ ] ID-84
[Proxy._delegate(address)](lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L22-L45) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L23-L44)

lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L22-L45


 - [ ] ID-85
[StorageSlot.getInt256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L103-L105)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L102-L106


 - [ ] ID-86
[StorageSlot.getBytesSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L130-L132)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L129-L133


 - [ ] ID-87
[EnumerableSet.values(EnumerableSet.UintSet)](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L365-L374) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L369-L371)

lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L365-L374


 - [ ] ID-88
[StorageSlot.getStringSlot(string)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L121-L123)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L120-L124


 - [ ] ID-89
[StorageSlot.getBytes32Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L85-L87)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L84-L88


 - [ ] ID-90
[StorageSlot.getBytesSlot(bytes)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L139-L141)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L138-L142


 - [ ] ID-91
[Address._revert(bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/Address.sol#L142-L145)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L138-L149


 - [ ] ID-92
[StorageSlot.getBooleanSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L76-L78)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L75-L79


 - [ ] ID-93
[EnumerableSet.values(EnumerableSet.Bytes32Set)](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L219-L228) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L223-L225)

lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L219-L228


 - [ ] ID-94
[StorageSlot.getStringSlot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L112-L114)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L111-L115


 - [ ] ID-95
[StorageSlot.getUint256Slot(bytes32)](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L94-L96)

lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L93-L97


 - [ ] ID-96
[EnumerableSet.values(EnumerableSet.AddressSet)](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L292-L301) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L296-L298)

lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L292-L301


## pragma
Impact: Informational
Confidence: High
 - [ ] ID-97
3 different versions of Solidity are used:
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)
	- Version constraint ^0.8.22 is used by:
		-[^0.8.22](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L4)
		-[^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)
	- Version constraint 0.8.28 is used by:
		-[0.8.28](src/BaseStrategy.sol#L2)
		-[0.8.28](src/ERC20MoonwellMorphoStrategy.sol#L2)
		-[0.8.28](src/interfaces/IBaseStrategy.sol#L2)
		-[0.8.28](src/interfaces/IDEXRouter.sol#L2)
		-[0.8.28](src/interfaces/IERC4626.sol#L2)
		-[0.8.28](src/interfaces/IMToken.sol#L2)
		-[0.8.28](src/interfaces/IMamoStrategyRegistry.sol#L2)
		-[0.8.28](src/interfaces/ISlippagePriceChecker.sol#L2)
		-[0.8.28](src/libraries/GPv2Order.sol#L2)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4


 - [ ] ID-98
3 different versions of Solidity are used:
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)
	- Version constraint ^0.8.22 is used by:
		-[^0.8.22](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L4)
		-[^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)
	- Version constraint 0.8.28 is used by:
		-[0.8.28](src/SlippagePriceChecker.sol#L2)
		-[0.8.28](src/interfaces/ISlippagePriceChecker.sol#L2)

lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L4


 - [ ] ID-99
3 different versions of Solidity are used:
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)
	- Version constraint ^0.8.22 is used by:
		-[^0.8.22](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L4)
		-[^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)
	- Version constraint 0.8.28 is used by:
		-[0.8.28](src/BaseStrategy.sol#L2)
		-[0.8.28](src/interfaces/IBaseStrategy.sol#L2)
		-[0.8.28](src/interfaces/IMamoStrategyRegistry.sol#L2)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4


 - [ ] ID-100
3 different versions of Solidity are used:
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)
	- Version constraint ^0.8.22 is used by:
		-[^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)
	- Version constraint 0.8.28 is used by:
		-[0.8.28](src/ERC1967Proxy.sol#L2)

lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4


 - [ ] ID-101
3 different versions of Solidity are used:
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](lib/openzeppelin-contracts/contracts/access/AccessControl.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/access/IAccessControl.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Context.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Pausable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L5)
	- Version constraint ^0.8.22 is used by:
		-[^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)
	- Version constraint 0.8.28 is used by:
		-[0.8.28](src/ERC1967Proxy.sol#L2)
		-[0.8.28](src/MamoStrategyRegistry.sol#L2)
		-[0.8.28](src/interfaces/IBaseStrategy.sol#L2)
		-[0.8.28](src/interfaces/IMamoStrategyRegistry.sol#L2)
		-[0.8.28](src/interfaces/IUUPSUpgradeable.sol#L2)

lib/openzeppelin-contracts/contracts/access/AccessControl.sol#L4


## dead-code
Impact: Informational
Confidence: Medium
 - [ ] ID-102
[UUPSUpgradeable.__UUPSUpgradeable_init()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66


 - [ ] ID-103
[UUPSUpgradeable.__UUPSUpgradeable_init_unchained()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69


 - [ ] ID-104
[Initializable._getInitializedVersion()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L208-L210) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L208-L210


 - [ ] ID-105
[Initializable._disableInitializers()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L192-L203) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L192-L203


 - [ ] ID-106
[ContextUpgradeable._msgData()](lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L27-L29) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L27-L29


 - [ ] ID-107
[ContextUpgradeable._contextSuffixLength()](lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L31-L33) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L31-L33


 - [ ] ID-108
[ContextUpgradeable.__Context_init_unchained()](lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L21-L22) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L21-L22


 - [ ] ID-109
[UUPSUpgradeable.__UUPSUpgradeable_init_unchained()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69


 - [ ] ID-110
[Initializable._getInitializedVersion()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L208-L210) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L208-L210


 - [ ] ID-111
[Initializable._disableInitializers()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L192-L203) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L192-L203


 - [ ] ID-112
[ContextUpgradeable.__Context_init()](lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L18-L19) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L18-L19


 - [ ] ID-113
[Initializable._isInitializing()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L215-L217) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L215-L217


 - [ ] ID-114
[Initializable._checkInitializing()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L178-L182) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L178-L182


 - [ ] ID-115
[Initializable._getInitializableStorage()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L223-L227) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L223-L227


 - [ ] ID-116
[UUPSUpgradeable.__UUPSUpgradeable_init()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66


 - [ ] ID-117
[UUPSUpgradeable.__UUPSUpgradeable_init_unchained()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69


 - [ ] ID-118
[Initializable._getInitializedVersion()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L208-L210) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L208-L210


 - [ ] ID-119
[BaseStrategy.__BaseStrategy_init(address)](src/BaseStrategy.sol#L82-L84) is never used and should be removed

src/BaseStrategy.sol#L82-L84


 - [ ] ID-120
[Initializable._disableInitializers()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L192-L203) is never used and should be removed

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L192-L203


 - [ ] ID-121
[AccessControl._setRoleAdmin(bytes32,bytes32)](lib/openzeppelin-contracts/contracts/access/AccessControl.sol#L170-L174) is never used and should be removed

lib/openzeppelin-contracts/contracts/access/AccessControl.sol#L170-L174


 - [ ] ID-122
[Context._contextSuffixLength()](lib/openzeppelin-contracts/contracts/utils/Context.sol#L25-L27) is never used and should be removed

lib/openzeppelin-contracts/contracts/utils/Context.sol#L25-L27


 - [ ] ID-123
[Context._msgData()](lib/openzeppelin-contracts/contracts/utils/Context.sol#L21-L23) is never used and should be removed

lib/openzeppelin-contracts/contracts/utils/Context.sol#L21-L23


## solc-version
Impact: Informational
Confidence: High
 - [ ] ID-124
Version constraint ^0.8.20 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess.
It is used by:
	- [^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4


 - [ ] ID-125
Version constraint ^0.8.22 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication.
It is used by:
	- [^0.8.22](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L4)
	- [^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L4


 - [ ] ID-126
Version constraint ^0.8.20 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess.
It is used by:
	- [^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)

lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L4


 - [ ] ID-127
Version constraint ^0.8.22 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication.
It is used by:
	- [^0.8.22](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L4)
	- [^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L4


 - [ ] ID-128
Version constraint ^0.8.20 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess.
It is used by:
	- [^0.8.20](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/draft-IERC1822.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4


 - [ ] ID-129
Version constraint ^0.8.22 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication.
It is used by:
	- [^0.8.22](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L4)
	- [^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L4


 - [ ] ID-130
Version constraint ^0.8.20 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess.
It is used by:
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)

lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4


 - [ ] ID-131
Version constraint ^0.8.22 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication.
It is used by:
	- [^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4


 - [ ] ID-132
Version constraint ^0.8.20 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess.
It is used by:
	- [^0.8.20](lib/openzeppelin-contracts/contracts/access/AccessControl.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/access/IAccessControl.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/IERC1967.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/proxy/Proxy.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Context.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Errors.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Pausable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol#L5)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L5)

lib/openzeppelin-contracts/contracts/access/AccessControl.sol#L4


 - [ ] ID-133
Version constraint ^0.8.22 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication.
It is used by:
	- [^0.8.22](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L4


## low-level-calls
Impact: Informational
Confidence: High
 - [ ] ID-134
Low level call in [Address.functionDelegateCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99):
	- [(success,returndata) = target.delegatecall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L97)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99


 - [ ] ID-135
Low level call in [Address.functionCallWithValue(address,bytes,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81):
	- [(success,returndata) = target.call{value: value}(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L79)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81


 - [ ] ID-136
Low level call in [Address.sendValue(address,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42):
	- [(success,returndata) = recipient.call{value: amount}()](lib/openzeppelin-contracts/contracts/utils/Address.sol#L38)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42


 - [ ] ID-137
Low level call in [Address.functionStaticCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90):
	- [(success,returndata) = target.staticcall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L88)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90


 - [ ] ID-138
Low level call in [Address.functionDelegateCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99):
	- [(success,returndata) = target.delegatecall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L97)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99


 - [ ] ID-139
Low level call in [Address.functionCallWithValue(address,bytes,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81):
	- [(success,returndata) = target.call{value: value}(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L79)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81


 - [ ] ID-140
Low level call in [Address.sendValue(address,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42):
	- [(success,returndata) = recipient.call{value: amount}()](lib/openzeppelin-contracts/contracts/utils/Address.sol#L38)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42


 - [ ] ID-141
Low level call in [Address.functionStaticCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90):
	- [(success,returndata) = target.staticcall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L88)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90


 - [ ] ID-142
Low level call in [Address.functionDelegateCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99):
	- [(success,returndata) = target.delegatecall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L97)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99


 - [ ] ID-143
Low level call in [Address.functionCallWithValue(address,bytes,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81):
	- [(success,returndata) = target.call{value: value}(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L79)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81


 - [ ] ID-144
Low level call in [Address.sendValue(address,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42):
	- [(success,returndata) = recipient.call{value: amount}()](lib/openzeppelin-contracts/contracts/utils/Address.sol#L38)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42


 - [ ] ID-145
Low level call in [Address.functionStaticCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90):
	- [(success,returndata) = target.staticcall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L88)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90


 - [ ] ID-146
Low level call in [Address.functionDelegateCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99):
	- [(success,returndata) = target.delegatecall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L97)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99


 - [ ] ID-147
Low level call in [Address.functionCallWithValue(address,bytes,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81):
	- [(success,returndata) = target.call{value: value}(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L79)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81


 - [ ] ID-148
Low level call in [Address.sendValue(address,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42):
	- [(success,returndata) = recipient.call{value: amount}()](lib/openzeppelin-contracts/contracts/utils/Address.sol#L38)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42


 - [ ] ID-149
Low level call in [Address.functionStaticCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90):
	- [(success,returndata) = target.staticcall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L88)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90


 - [ ] ID-150
Low level call in [Address.functionDelegateCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99):
	- [(success,returndata) = target.delegatecall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L97)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L96-L99


 - [ ] ID-151
Low level call in [Address.functionCallWithValue(address,bytes,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81):
	- [(success,returndata) = target.call{value: value}(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L79)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L75-L81


 - [ ] ID-152
Low level call in [Address.sendValue(address,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42):
	- [(success,returndata) = recipient.call{value: amount}()](lib/openzeppelin-contracts/contracts/utils/Address.sol#L38)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L33-L42


 - [ ] ID-153
Low level call in [Address.functionStaticCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90):
	- [(success,returndata) = target.staticcall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L88)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L87-L90


## naming-convention
Impact: Informational
Confidence: High
 - [ ] ID-154
Function [BaseStrategy.__BaseStrategy_init(address)](src/BaseStrategy.sol#L82-L84) is not in mixedCase

src/BaseStrategy.sol#L82-L84


 - [ ] ID-155
Parameter [ERC20MoonwellMorphoStrategy.setSlippage(uint256)._newSlippageInBps](src/ERC20MoonwellMorphoStrategy.sol#L168) is not in mixedCase

src/ERC20MoonwellMorphoStrategy.sol#L168


 - [ ] ID-156
Function [UUPSUpgradeable.__UUPSUpgradeable_init_unchained()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69


 - [ ] ID-157
Variable [UUPSUpgradeable.__self](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L22) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L22


 - [ ] ID-158
Function [UUPSUpgradeable.__UUPSUpgradeable_init()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66


 - [ ] ID-159
Parameter [BaseStrategy.__BaseStrategy_init(address)._mamoStrategyRegistry](src/BaseStrategy.sol#L82) is not in mixedCase

src/BaseStrategy.sol#L82


 - [ ] ID-160
Parameter [SlippagePriceChecker.getExpectedOutFromChainlink(address[],bool[],uint256,address,address)._priceFeeds](src/SlippagePriceChecker.sol#L200) is not in mixedCase

src/SlippagePriceChecker.sol#L200


 - [ ] ID-161
Parameter [SlippagePriceChecker.getExpectedOut(uint256,address,address)._amountIn](src/SlippagePriceChecker.sol#L164) is not in mixedCase

src/SlippagePriceChecker.sol#L164


 - [ ] ID-162
Parameter [SlippagePriceChecker.getExpectedOutFromChainlink(address[],bool[],uint256,address,address)._fromToken](src/SlippagePriceChecker.sol#L203) is not in mixedCase

src/SlippagePriceChecker.sol#L203


 - [ ] ID-163
Constant [OwnableUpgradeable.OwnableStorageLocation](lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L28) is not in UPPER_CASE_WITH_UNDERSCORES

lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L28


 - [ ] ID-164
Parameter [SlippagePriceChecker.getExpectedOutFromChainlink(address[],bool[],uint256,address,address)._reverses](src/SlippagePriceChecker.sol#L201) is not in mixedCase

src/SlippagePriceChecker.sol#L201


 - [ ] ID-165
Function [OwnableUpgradeable.__Ownable_init(address)](lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L51-L53) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L51-L53


 - [ ] ID-166
Parameter [SlippagePriceChecker.getExpectedOutFromChainlink(address[],bool[],uint256,address,address)._toToken](src/SlippagePriceChecker.sol#L204) is not in mixedCase

src/SlippagePriceChecker.sol#L204


 - [ ] ID-167
Function [OwnableUpgradeable.__Ownable_init_unchained(address)](lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L55-L60) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol#L55-L60


 - [ ] ID-168
Parameter [SlippagePriceChecker.checkPrice(uint256,address,address,uint256,uint256)._amountIn](src/SlippagePriceChecker.sol#L121) is not in mixedCase

src/SlippagePriceChecker.sol#L121


 - [ ] ID-169
Function [ContextUpgradeable.__Context_init_unchained()](lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L21-L22) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L21-L22


 - [ ] ID-170
Parameter [SlippagePriceChecker.checkPrice(uint256,address,address,uint256,uint256)._fromToken](src/SlippagePriceChecker.sol#L122) is not in mixedCase

src/SlippagePriceChecker.sol#L122


 - [ ] ID-171
Parameter [SlippagePriceChecker.checkPrice(uint256,address,address,uint256,uint256)._slippageInBps](src/SlippagePriceChecker.sol#L125) is not in mixedCase

src/SlippagePriceChecker.sol#L125


 - [ ] ID-172
Parameter [SlippagePriceChecker.checkPrice(uint256,address,address,uint256,uint256)._minOut](src/SlippagePriceChecker.sol#L124) is not in mixedCase

src/SlippagePriceChecker.sol#L124


 - [ ] ID-173
Function [UUPSUpgradeable.__UUPSUpgradeable_init_unchained()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69


 - [ ] ID-174
Parameter [SlippagePriceChecker.getExpectedOutFromChainlink(address[],bool[],uint256,address,address)._amountIn](src/SlippagePriceChecker.sol#L202) is not in mixedCase

src/SlippagePriceChecker.sol#L202


 - [ ] ID-175
Parameter [SlippagePriceChecker.getExpectedOut(uint256,address,address)._toToken](src/SlippagePriceChecker.sol#L164) is not in mixedCase

src/SlippagePriceChecker.sol#L164


 - [ ] ID-176
Parameter [SlippagePriceChecker.getExpectedOut(uint256,address,address)._fromToken](src/SlippagePriceChecker.sol#L164) is not in mixedCase

src/SlippagePriceChecker.sol#L164


 - [ ] ID-177
Parameter [SlippagePriceChecker.initialize(address)._owner](src/SlippagePriceChecker.sol#L57) is not in mixedCase

src/SlippagePriceChecker.sol#L57


 - [ ] ID-178
Variable [UUPSUpgradeable.__self](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L22) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L22


 - [ ] ID-179
Function [UUPSUpgradeable.__UUPSUpgradeable_init()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66


 - [ ] ID-180
Parameter [SlippagePriceChecker.addTokenConfiguration(address,ISlippagePriceChecker.TokenFeedConfiguration[],uint256)._maxTimePriceValid](src/SlippagePriceChecker.sol#L74) is not in mixedCase

src/SlippagePriceChecker.sol#L74


 - [ ] ID-181
Parameter [SlippagePriceChecker.checkPrice(uint256,address,address,uint256,uint256)._toToken](src/SlippagePriceChecker.sol#L123) is not in mixedCase

src/SlippagePriceChecker.sol#L123


 - [ ] ID-182
Function [ContextUpgradeable.__Context_init()](lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L18-L19) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol#L18-L19


 - [ ] ID-183
Function [BaseStrategy.__BaseStrategy_init(address)](src/BaseStrategy.sol#L82-L84) is not in mixedCase

src/BaseStrategy.sol#L82-L84


 - [ ] ID-184
Function [UUPSUpgradeable.__UUPSUpgradeable_init_unchained()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L68-L69


 - [ ] ID-185
Variable [UUPSUpgradeable.__self](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L22) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L22


 - [ ] ID-186
Function [UUPSUpgradeable.__UUPSUpgradeable_init()](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66) is not in mixedCase

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol#L65-L66


 - [ ] ID-187
Parameter [BaseStrategy.__BaseStrategy_init(address)._mamoStrategyRegistry](src/BaseStrategy.sol#L82) is not in mixedCase

src/BaseStrategy.sol#L82


## reentrancy-unlimited-gas
Impact: Informational
Confidence: Medium
 - [ ] ID-188
Reentrancy in [BaseStrategy.recoverETH(address)](src/BaseStrategy.sol#L61-L67):
	External calls:
	- [to.transfer(amount)](src/BaseStrategy.sol#L64)
	Event emitted after the call(s):
	- [TokenRecovered(address(0),to,amount)](src/BaseStrategy.sol#L66)

src/BaseStrategy.sol#L61-L67


 - [ ] ID-189
Reentrancy in [BaseStrategy.recoverETH(address)](src/BaseStrategy.sol#L61-L67):
	External calls:
	- [to.transfer(amount)](src/BaseStrategy.sol#L64)
	Event emitted after the call(s):
	- [TokenRecovered(address(0),to,amount)](src/BaseStrategy.sol#L66)

src/BaseStrategy.sol#L61-L67


## unused-import
Impact: Informational
Confidence: High
 - [ ] ID-190
The following unused import(s) in src/ERC20MoonwellMorphoStrategy.sol should be removed:
	-import {IDEXRouter} from "@interfaces/IDEXRouter.sol"; (src/ERC20MoonwellMorphoStrategy.sol#5)

 - [ ] ID-191
The following unused import(s) in src/SlippagePriceChecker.sol should be removed:
	-import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol"; (src/SlippagePriceChecker.sol#11)

## divide-before-multiply
Impact: Medium
Confidence: Medium
 - [ ] ID-192
[SlippagePriceChecker.getExpectedOutFromChainlink(address[],bool[],uint256,address,address)](src/SlippagePriceChecker.sol#L199-L238) performs a multiplication on the result of a division:
	- [_expectedOutFromChainlink = _expectedOutFromChainlink / (10 ** (_fromTokenDecimals - _toTokenDecimals))](src/SlippagePriceChecker.sol#L234)
	- [_amountIntoThisIteration = _expectedOutFromChainlink](src/SlippagePriceChecker.sol#L220)
	- [_expectedOutFromChainlink = (_amountIntoThisIteration * _scaleAnswerBy) / uint256(_latestAnswer)](src/SlippagePriceChecker.sol#L224-L226)

src/SlippagePriceChecker.sol#L199-L238


 - [ ] ID-193
[SlippagePriceChecker.getExpectedOutFromChainlink(address[],bool[],uint256,address,address)](src/SlippagePriceChecker.sol#L199-L238) performs a multiplication on the result of a division:
	- [_expectedOutFromChainlink = _expectedOutFromChainlink / (10 ** (_fromTokenDecimals - _toTokenDecimals))](src/SlippagePriceChecker.sol#L234)
	- [_amountIntoThisIteration = _expectedOutFromChainlink](src/SlippagePriceChecker.sol#L220)
	- [_expectedOutFromChainlink = (_amountIntoThisIteration * uint256(_latestAnswer)) / _scaleAnswerBy](src/SlippagePriceChecker.sol#L224-L226)

src/SlippagePriceChecker.sol#L199-L238


## unchecked-transfer
Impact: High
Confidence: Medium
 - [ ] ID-194
[MamoStrategyRegistry.recoverERC20(address,address,uint256)](src/MamoStrategyRegistry.sol#L238-L243) ignores return value by [IERC20(tokenAddress).transfer(to,amount)](src/MamoStrategyRegistry.sol#L242)

src/MamoStrategyRegistry.sol#L238-L243


