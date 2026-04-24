**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [incorrect-exp](#incorrect-exp) (1 results) (High)
 - [uninitialized-state](#uninitialized-state) (14 results) (High)
 - [divide-before-multiply](#divide-before-multiply) (9 results) (Medium)
 - [incorrect-equality](#incorrect-equality) (2 results) (Medium)
 - [unused-return](#unused-return) (2 results) (Medium)
 - [cache-array-length](#cache-array-length) (3 results) (Optimization)
 - [constable-states](#constable-states) (12 results) (Optimization)
## incorrect-exp
Impact: High
Confidence: Medium
 - [ ] ID-0
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275) has bitwise-xor operator ^ instead of the exponentiation operator **: 
	 - [inverse = (3 * denominator) ^ 2](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L257)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275


## uninitialized-state
Impact: High
Confidence: High
 - [ ] ID-1
[DiscountBillStorage.compliance](src/DiscountBillStorage.sol#L106) is never initialized. It is used in:
	- [DiscountBillStorage._enforceComplianceAndTravel(address,address,address,uint256)](src/DiscountBillStorage.sol#L211-L219)
	- [DiscountBillLifecycle.updateDepositWallet(uint256,address)](src/DiscountBillLifecycle.sol#L334-L346)

src/DiscountBillStorage.sol#L106


 - [ ] ID-2
[DiscountBillStorage.maxDepositAmount](src/DiscountBillStorage.sol#L141) is never initialized. It is used in:
	- [DiscountBillCampaigns._issueInternal(address,address,address,address,address,uint256,uint256,uint256)](src/DiscountBillCampaigns.sol#L249-L310)

src/DiscountBillStorage.sol#L141


 - [ ] ID-3
[DiscountBillStorage.compliance](src/DiscountBillStorage.sol#L106) is never initialized. It is used in:
	- [DiscountBillStorage._enforceComplianceAndTravel(address,address,address,uint256)](src/DiscountBillStorage.sol#L211-L219)

src/DiscountBillStorage.sol#L106


 - [ ] ID-4
[DiscountBillStorage.commissionBps](src/DiscountBillStorage.sol#L114) is never initialized. It is used in:
	- [DiscountBillCampaigns._issueInternal(address,address,address,address,address,uint256,uint256,uint256)](src/DiscountBillCampaigns.sol#L249-L310)

src/DiscountBillStorage.sol#L114


 - [ ] ID-5
[DiscountBillStorage.treasury](src/DiscountBillStorage.sol#L109) is never initialized. It is used in:
	- [DiscountBillLifecycle.approveEarlyRedemption(uint256)](src/DiscountBillLifecycle.sol#L116-L182)
	- [DiscountBillLifecycle.merge(uint256[],uint256)](src/DiscountBillLifecycle.sol#L218-L284)

src/DiscountBillStorage.sol#L109


 - [ ] ID-6
[DiscountBillStorage.billSeries](src/DiscountBillStorage.sol#L176) is never initialized. It is used in:
	- [DiscountBillLifecycle._aggregateBills(uint256[],uint256,IDiscountBill.BillInfo)](src/DiscountBillLifecycle.sol#L286-L328)

src/DiscountBillStorage.sol#L176


 - [ ] ID-7
[DiscountBillStorage.travel](src/DiscountBillStorage.sol#L107) is never initialized. It is used in:
	- [DiscountBillStorage._enforceComplianceAndTravel(address,address,address,uint256)](src/DiscountBillStorage.sol#L211-L219)
	- [DiscountBillCampaigns._burnExpiredSingle(uint256)](src/DiscountBillCampaigns.sol#L91-L146)

src/DiscountBillStorage.sol#L107


 - [ ] ID-8
[DiscountBillStorage.billTokenFactory](src/DiscountBillStorage.sol#L140) is never initialized. It is used in:
	- [DiscountBillLifecycle._deployBillToken(uint256,address,uint256,address,uint256)](src/DiscountBillLifecycle.sol#L373-L391)

src/DiscountBillStorage.sol#L140


 - [ ] ID-9
[DiscountBillStorage.billTokenFactory](src/DiscountBillStorage.sol#L140) is never initialized. It is used in:
	- [DiscountBillCampaigns._deployBillToken(uint256,address,uint256,address,uint256)](src/DiscountBillCampaigns.sol#L316-L334)

src/DiscountBillStorage.sol#L140


 - [ ] ID-10
[DiscountBillStorage.issuer](src/DiscountBillStorage.sol#L108) is never initialized. It is used in:
	- [DiscountBillCampaigns._burnExpiredSingle(uint256)](src/DiscountBillCampaigns.sol#L91-L146)
	- [DiscountBillCampaigns._issueInternal(address,address,address,address,address,uint256,uint256,uint256)](src/DiscountBillCampaigns.sol#L249-L310)

src/DiscountBillStorage.sol#L108


 - [ ] ID-11
[DiscountBillStorage.issuer](src/DiscountBillStorage.sol#L108) is never initialized. It is used in:
	- [DiscountBillLifecycle.approveEarlyRedemption(uint256)](src/DiscountBillLifecycle.sol#L116-L182)

src/DiscountBillStorage.sol#L108


 - [ ] ID-12
[DiscountBillStorage.defaultClaimWindow](src/DiscountBillStorage.sol#L154) is never initialized. It is used in:
	- [DiscountBillCore._issueInternal(address,address,address,address,address,uint256,uint256,uint256)](src/DiscountBillCore.sol#L129-L190)

src/DiscountBillStorage.sol#L154


 - [ ] ID-13
[DiscountBillStorage.travel](src/DiscountBillStorage.sol#L107) is never initialized. It is used in:
	- [DiscountBillStorage._enforceComplianceAndTravel(address,address,address,uint256)](src/DiscountBillStorage.sol#L211-L219)
	- [DiscountBillLifecycle.approveEarlyRedemption(uint256)](src/DiscountBillLifecycle.sol#L116-L182)

src/DiscountBillStorage.sol#L107


 - [ ] ID-14
[DiscountBillStorage.treasury](src/DiscountBillStorage.sol#L109) is never initialized. It is used in:
	- [DiscountBillCampaigns._burnExpiredSingle(uint256)](src/DiscountBillCampaigns.sol#L91-L146)
	- [DiscountBillCampaigns._issueInternal(address,address,address,address,address,uint256,uint256,uint256)](src/DiscountBillCampaigns.sol#L249-L310)

src/DiscountBillStorage.sol#L109


## divide-before-multiply
Impact: Medium
Confidence: Medium
 - [ ] ID-15
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L242)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L265)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275


 - [ ] ID-16
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L242)
	- [inverse = (3 * denominator) ^ 2](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L257)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275


 - [ ] ID-17
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275) performs a multiplication on the result of a division:
	- [low = low / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L245)
	- [result = low * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L272)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275


 - [ ] ID-18
[Math.invMod(uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L315-L361) performs a multiplication on the result of a division:
	- [quotient = gcd / remainder](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L337)
	- [(gcd,remainder) = (remainder,gcd - remainder * quotient)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L339-L346)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L315-L361


 - [ ] ID-19
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L242)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L263)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275


 - [ ] ID-20
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L242)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L261)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275


 - [ ] ID-21
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L242)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L266)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275


 - [ ] ID-22
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L242)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L264)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275


 - [ ] ID-23
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L242)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L262)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L204-L275


## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-24
[DiscountBillCampaigns.isExpired(uint256)](src/DiscountBillCampaigns.sol#L71-L77) uses a dangerous strict equality:
	- [deadline == 0](src/DiscountBillCampaigns.sol#L73)

src/DiscountBillCampaigns.sol#L71-L77


 - [ ] ID-25
[DiscountBillERC5095Upgradeable.isExpired(uint256)](src/DiscountBillERC5095Upgradeable.sol#L786-L792) uses a dangerous strict equality:
	- [deadline == 0](src/DiscountBillERC5095Upgradeable.sol#L788)

src/DiscountBillERC5095Upgradeable.sol#L786-L792


## unused-return
Impact: Medium
Confidence: Medium
 - [ ] ID-26
[ERC1967Utils.upgradeBeaconToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166) ignores return value by [Address.functionDelegateCall(IBeacon(newBeacon).implementation(),data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L162)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L157-L166


 - [ ] ID-27
[ERC1967Utils.upgradeToAndCall(address,bytes)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76) ignores return value by [Address.functionDelegateCall(newImplementation,data)](lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L72)

lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol#L67-L76


## cache-array-length
Impact: Optimization
Confidence: High
 - [ ] ID-28
Loop condition [i < _trackedTokens.length](src/TreasuryUpgradeable.sol#L553) should use cached array length instead of referencing `length` member of the storage array.
 
src/TreasuryUpgradeable.sol#L553


 - [ ] ID-29
Loop condition [i < _strategies.length](src/TreasuryUpgradeable.sol#L886) should use cached array length instead of referencing `length` member of the storage array.
 
src/TreasuryUpgradeable.sol#L886


 - [ ] ID-30
Loop condition [i < _strategies.length](src/TreasuryUpgradeable.sol#L728) should use cached array length instead of referencing `length` member of the storage array.
 
src/TreasuryUpgradeable.sol#L728


## constable-states
Impact: Optimization
Confidence: High
 - [ ] ID-31
[DiscountBillStorage.commissionBps](src/DiscountBillStorage.sol#L114) should be constant 

src/DiscountBillStorage.sol#L114


 - [ ] ID-32
[DiscountBillStorage.treasury](src/DiscountBillStorage.sol#L109) should be constant 

src/DiscountBillStorage.sol#L109


 - [ ] ID-33
[DiscountBillStorage.compliance](src/DiscountBillStorage.sol#L106) should be constant 

src/DiscountBillStorage.sol#L106


 - [ ] ID-34
[DiscountBillStorage.travel](src/DiscountBillStorage.sol#L107) should be constant 

src/DiscountBillStorage.sol#L107


 - [ ] ID-35
[DiscountBillStorage.lifecycleImpl](src/DiscountBillStorage.sol#L183) should be constant 

src/DiscountBillStorage.sol#L183


 - [ ] ID-36
[DiscountBillStorage.claimWindowEffectiveFrom](src/DiscountBillStorage.sol#L155) should be constant 

src/DiscountBillStorage.sol#L155


 - [ ] ID-37
[DiscountBillStorage.issuer](src/DiscountBillStorage.sol#L108) should be constant 

src/DiscountBillStorage.sol#L108


 - [ ] ID-38
[DiscountBillStorage.billTokenFactory](src/DiscountBillStorage.sol#L140) should be constant 

src/DiscountBillStorage.sol#L140


 - [ ] ID-39
[DiscountBillStorage.nextSeriesId](src/DiscountBillStorage.sol#L177) should be constant 

src/DiscountBillStorage.sol#L177


 - [ ] ID-40
[DiscountBillStorage.defaultBreakFeeBps](src/DiscountBillStorage.sol#L134) should be constant 

src/DiscountBillStorage.sol#L134


 - [ ] ID-41
[DiscountBillStorage.campaignsImpl](src/DiscountBillStorage.sol#L184) should be constant 

src/DiscountBillStorage.sol#L184


 - [ ] ID-42
[DiscountBillStorage.defaultClaimWindow](src/DiscountBillStorage.sol#L154) should be constant 

src/DiscountBillStorage.sol#L154


