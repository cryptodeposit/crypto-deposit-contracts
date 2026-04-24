// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DiscountBillERC5095Upgradeable} from "../src/DiscountBillERC5095Upgradeable.sol";
import {DiscountBillERC5095Token, BillTokenFactory} from "../src/BillTokenFactory.sol";
import {TreasuryUpgradeable} from "../src/TreasuryUpgradeable.sol";
import {IComplianceRegistry} from "../src/interfaces/IComplianceRegistry.sol";
import {ITravelRuleRegistry} from "../src/interfaces/ITravelRuleRegistry.sol";
import {IDiscountBill} from "../src/interfaces/IDiscountBill.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";

contract ComplianceRegistryMock is IComplianceRegistry {
    mapping(address => bool) private _blocked;

    function setBlocked(address account, bool blocked) external {
        _blocked[account] = blocked;
    }

    function isAllowed(address account) external view returns (bool) {
        return !_blocked[account];
    }
}

contract TravelRuleRegistryMock is ITravelRuleRegistry {
    bool public compliant = true;
    uint256 public consumeCount;
    address public lastToken;
    address public lastFrom;
    address public lastTo;
    uint256 public lastAmount;

    function setCompliant(bool value) external {
        compliant = value;
    }

    function isCompliant(address, address from, address to, uint256 amount) external view returns (bool) {
        from;
        to;
        amount;
        return compliant;
    }

    function consume(address token, address from, address to, uint256 amount) external {
        require(compliant, "not compliant");
        consumeCount++;
        lastToken = token;
        lastFrom = from;
        lastTo = to;
        lastAmount = amount;
    }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("MockToken", "MTK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DecimalsReverter is ERC20 {
    constructor() ERC20("NoDecimals", "NODEC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        revert("no decimals");
    }
}

contract DiscountBillERC5095UpgradeableTest is Test {
    DiscountBillERC5095Upgradeable private bill;
    ComplianceRegistryMock private compliance;
    TravelRuleRegistryMock private travel;
    MockERC20 private token;
    DecimalsReverter private noDecimalsToken;
    bytes4 private constant ERC20_BALANCE_SELECTOR =
        bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)"));

    address private admin = makeAddr("admin");
    address private issuer = makeAddr("issuer");
    address private depositor = makeAddr("depositor");
    address private owner = makeAddr("owner");
    address private depositWallet = makeAddr("depositWallet");
    address private introducingWallet = makeAddr("introducingWallet");
    uint256 private constant PRINCIPAL = 1_000 ether;

    function setUp() public {
        compliance = new ComplianceRegistryMock();
        travel = new TravelRuleRegistryMock();
        token = new MockERC20();
        noDecimalsToken = new DecimalsReverter();
        DiscountBillERC5095Upgradeable impl = new DiscountBillERC5095Upgradeable();
        bill = DiscountBillERC5095Upgradeable(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(DiscountBillERC5095Upgradeable.initialize, (admin, issuer, compliance, travel))
                )
            )
        );

        BillTokenFactory factory = new BillTokenFactory();
        vm.prank(admin);
        bill.setBillTokenFactory(address(factory));

        token.mint(depositor, 10_000 ether);
        token.mint(issuer, 10_000 ether);
        noDecimalsToken.mint(depositor, 1_000 ether);
        noDecimalsToken.mint(issuer, 1_000 ether);

        vm.prank(issuer);
        token.approve(address(bill), type(uint256).max);
        vm.prank(depositor);
        token.approve(address(bill), type(uint256).max);

        vm.prank(issuer);
        noDecimalsToken.approve(address(bill), type(uint256).max);
        vm.prank(depositor);
        noDecimalsToken.approve(address(bill), type(uint256).max);
    }

    function testInitializeSetsRolesAndState() public view {
        assertTrue(bill.hasRole(bill.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(bill.hasRole(bill.ISSUER_ROLE(), issuer));
        assertTrue(bill.hasRole(bill.OPERATOR_ROLE(), admin));
        assertTrue(bill.hasRole(bill.UPGRADER_ROLE(), admin));
        assertEq(address(bill.complianceRegistry()), address(compliance));
        assertEq(address(bill.travelRuleRegistry()), address(travel));
        assertEq(bill.commissionRateBps(), 1500);
        assertEq(bill.nextBillId(), 1);
    }

    function testIssueCreatesBillTokenAndTransfersPrincipal() public {
        uint256 issuerBefore = token.balanceOf(issuer);
        uint256 depositorBefore = token.balanceOf(depositor);

        (uint256 billId, uint256 redemptionValue,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        assertEq(bill.ownerOf(billId), owner);
        assertEq(info.principal, PRINCIPAL);
        assertEq(info.depositWallet, depositWallet);
        assertEq(token.balanceOf(issuer), issuerBefore + PRINCIPAL);
        assertEq(token.balanceOf(depositor), depositorBefore - PRINCIPAL);

        DiscountBillERC5095Token billToken = DiscountBillERC5095Token(bill.billTokens(billId));
        assertEq(billToken.totalSupply(), redemptionValue);
        assertEq(billToken.balanceOf(owner), redemptionValue);
        assertEq(billToken.underlying(), address(token));
        assertEq(billToken.maturity(), info.maturity);
        assertEq(billToken.decimals(), token.decimals());
    }

    function testIssueRevertsOnBadInput() public {
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.InvalidAmount.selector);
        bill.issue(owner, depositor, depositWallet, introducingWallet, address(token), 0, 10_000, 10);

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.InvalidRate.selector);
        bill.issue(owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 100_001, 10);

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.InvalidDuration.selector);
        bill.issue(owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 10_000, 0);

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.ZeroAddress.selector);
        bill.issue(owner, address(0), depositWallet, introducingWallet, address(token), PRINCIPAL, 10_000, 10);
    }

    function testRedeemFullViaNftPaysOutAndBurns() public {
        (uint256 billId, uint256 finalAmount, uint256 commission) = _issueDefault(address(token));
        vm.warp(block.timestamp + 2 days);

        uint256 depositBefore = token.balanceOf(depositWallet);
        uint256 introBefore = token.balanceOf(introducingWallet);

        vm.prank(owner);
        bill.redeem(billId);

        assertEq(token.balanceOf(depositWallet), depositBefore + finalAmount - commission);
        assertEq(token.balanceOf(introducingWallet), introBefore + commission);
        vm.expectRevert();
        bill.ownerOf(billId);
        assertEq(bill.redeemableValue(billId), 0);

        DiscountBillERC5095Token billToken = DiscountBillERC5095Token(bill.billTokens(billId));
        vm.expectRevert(bytes("Redeem unavailable"));
        billToken.redeem(1, depositWallet, owner);
    }

    function testPartialRedemptionViaTokenThenFinalizeViaNft() public {
        (uint256 billId, uint256 finalAmount, uint256 commission) = _issueDefault(address(token));
        DiscountBillERC5095Token billToken = DiscountBillERC5095Token(bill.billTokens(billId));

        vm.warp(block.timestamp + 1 days);
        uint256 half = finalAmount / 2;
        uint256 netHalf = bill.previewRedeem(billId, half);
        uint256 commissionHalf = Math.mulDiv(commission, half, finalAmount);

        vm.prank(owner);
        uint256 payout = billToken.redeem(half, depositWallet, owner);

        assertEq(payout, netHalf);
        assertEq(token.balanceOf(depositWallet), netHalf);
        assertEq(billToken.balanceOf(owner), finalAmount - half);

        IDiscountBill.BillInfo memory afterFirst = bill.getBillInfo(billId);
        assertEq(afterFirst.redemptionValue, finalAmount - half);
        assertEq(afterFirst.commissionAmount, commission - commissionHalf);

        uint256 netRemaining = bill.previewRedeem(billId, afterFirst.redemptionValue);
        vm.prank(owner);
        bill.redeem(billId);

        assertEq(token.balanceOf(depositWallet), netHalf + netRemaining);
        assertEq(token.balanceOf(introducingWallet), commission);
        vm.expectRevert();
        bill.ownerOf(billId);
    }

    function testRedeemEmitsDefaultWhenIssuerInsolvent() public {
        (uint256 billId, uint256 redemptionValue,) = _issueDefault(address(token));
        vm.warp(block.timestamp + 1 days);
        _setTokenBalance(address(token), issuer, 0);

        // redeem() no longer reverts on insolvency; it emits Defaulted and returns 0
        vm.prank(owner);
        bill.redeem(billId);

        // The bill's redemptionValue is preserved (not zeroed) since transfer didn't happen,
        // but billInvalidated is set to true
        assertEq(bill.redeemableValue(billId), redemptionValue);
        assertEq(token.balanceOf(depositWallet), 0);
        assertTrue(bill.billInvalidated(billId));
    }

    function testTokenRedeemRevertsOnDefault() public {
        (uint256 billId,,) = _issueDefault(address(token));
        DiscountBillERC5095Token billToken = DiscountBillERC5095Token(bill.billTokens(billId));
        vm.warp(block.timestamp + 1 days);

        _setTokenBalance(address(token), issuer, 0);

        // canRedeem returns false when issuer has insufficient balance,
        // so the bill token's redeem reverts with "Redeem unavailable"
        uint256 ownerBalance = billToken.balanceOf(owner);
        vm.expectRevert(bytes("Redeem unavailable"));
        vm.prank(owner);
        billToken.redeem(ownerBalance, depositWallet, owner);
    }

    function testPreviewAndCanRedeemReflectState() public {
        (uint256 billId, uint256 finalAmount, uint256 commission) = _issueDefault(address(token));
        uint256 sample = finalAmount / 3;
        assertFalse(bill.canRedeem(billId, sample));
        vm.expectRevert(DiscountBillERC5095Upgradeable.NotMature.selector);
        bill.redeem(billId);

        vm.expectRevert(DiscountBillERC5095Upgradeable.ExceedsValue.selector);
        bill.previewRedeem(billId, finalAmount + 1);

        vm.warp(block.timestamp + 1 days);
        uint256 expectedNet = bill.previewRedeem(billId, sample);
        assertEq(expectedNet, sample - Math.mulDiv(commission, sample, finalAmount));
        assertTrue(bill.canRedeem(billId, sample));

        _setTokenBalance(address(token), issuer, 0);
        assertFalse(bill.canRedeem(billId, sample));
    }

    function testDecimalsFallbackWhenUnderlyingDecimalsReverts() public {
        vm.prank(admin);
        uint256 billId = bill.issue(
            owner,
            depositor,
            depositWallet,
            introducingWallet,
            address(noDecimalsToken),
            PRINCIPAL,
            36_500,
            1
        );

        DiscountBillERC5095Token billToken = DiscountBillERC5095Token(bill.billTokens(billId));
        assertEq(billToken.decimals(), 18);
    }

    function _issueDefault(address tokenAddr)
        internal
        returns (uint256 billId, uint256 redemptionValue, uint256 commission)
    {
        vm.prank(admin);
        billId = bill.issue(
            owner, depositor, depositWallet, introducingWallet, tokenAddr, PRINCIPAL, 36_500, 1
        );
        (redemptionValue, commission) = _expectedPayout(PRINCIPAL, 36_500, 1);
    }

    function _expectedPayout(uint256 principal, uint256 annualRateBps, uint256 durationDays)
        internal
        pure
        returns (uint256 finalAmount, uint256 commission)
    {
        uint256 ratePerDayBps = annualRateBps / 365;
        uint256 ratePerDayScaled = (ratePerDayBps * 1e18) / 10_000;
        uint256 growth = 1e18;
        uint256 multiplier = 1e18 + ratePerDayScaled;
        for (uint256 i = 0; i < durationDays; i++) {
            growth = Math.mulDiv(growth, multiplier, 1e18, Math.Rounding.Floor);
        }
        finalAmount = Math.mulDiv(principal, growth, 1e18, Math.Rounding.Floor);
        uint256 interest = finalAmount > principal ? finalAmount - principal : 0;
        commission = (interest * 1500) / 10_000;
    }

    function _setTokenBalance(address tokenAddr, address account, uint256 amount) internal {
        // _balances mapping is slot 0 in OZ ERC20
        bytes32 slot = keccak256(abi.encode(account, uint256(0)));
        vm.store(tokenAddr, slot, bytes32(amount));
    }

    // ========== BREAK FEE CONFIGURATION TESTS ==========

    function testSetBreakFeeForSpecificToken() public {
        vm.prank(admin);
        bill.setBreakFee(address(token), 300); // 3%

        assertEq(bill.getBreakFee(address(token)), 300);
        assertEq(bill.defaultBreakFeeBps(), 500); // Default unchanged
    }

    function testSetDefaultBreakFee() public {
        vm.prank(admin);
        bill.setBreakFee(address(0), 750); // 7.5%

        assertEq(bill.defaultBreakFeeBps(), 750);
        // Token without specific fee uses default
        assertEq(bill.getBreakFee(address(token)), 750);
    }

    function testSetBreakFeeRevertsOnExceedMax() public {
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.FeeExceedsMax.selector);
        bill.setBreakFee(address(token), 2001); // > 20%
    }

    function testSetBreakFeeRevertsForNonOperator() public {
        vm.prank(owner);
        vm.expectRevert();
        bill.setBreakFee(address(token), 300);
    }

    function testGetBreakFeeFallsBackToDefault() public {
        // Token without specific fee should use default
        assertEq(bill.getBreakFee(address(token)), 500); // Default 5%

        // Set specific fee for token
        vm.prank(admin);
        bill.setBreakFee(address(token), 300);
        assertEq(bill.getBreakFee(address(token)), 300);

        // Another token still uses default
        address otherToken = makeAddr("otherToken");
        assertEq(bill.getBreakFee(otherToken), 500);
    }

    // ========== EARLY REDEMPTION REQUEST TESTS ==========

    function testRequestEarlyRedemptionFull() public {
        (uint256 billId,,) = _issueDefault(address(token));

        // Move time forward but not to maturity
        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, false, 0);

        DiscountBillERC5095Upgradeable.EarlyRedemptionRequest memory req =
            bill.getEarlyRedemptionRequest(requestId);

        assertEq(req.billId, billId);
        assertEq(req.requester, owner);
        assertFalse(req.isPartial);
        assertTrue(req.breakFee > 0);
        assertTrue(req.accruedInterest > 0);
        assertTrue(req.payoutAmount > 0);
        assertEq(uint256(req.status), uint256(DiscountBillERC5095Upgradeable.RedemptionStatus.Pending));
    }

    function testRequestEarlyRedemptionPartial() public {
        (uint256 billId, uint256 redemptionValue,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        uint256 partialAmount = redemptionValue / 2;
        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, true, partialAmount);

        DiscountBillERC5095Upgradeable.EarlyRedemptionRequest memory req =
            bill.getEarlyRedemptionRequest(requestId);

        assertEq(req.amount, partialAmount);
        assertTrue(req.isPartial);
    }

    function testRequestEarlyRedemptionRevertsIfMature() public {
        (uint256 billId,,) = _issueDefault(address(token));

        // Move to maturity
        vm.warp(block.timestamp + 2 days);

        vm.prank(owner);
        vm.expectRevert(DiscountBillERC5095Upgradeable.AlreadyMature.selector);
        bill.requestEarlyRedemption(billId, false, 0);
    }

    function testRequestEarlyRedemptionRevertsIfNotOwner() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.prank(depositor);
        vm.expectRevert(DiscountBillERC5095Upgradeable.NotOwner.selector);
        bill.requestEarlyRedemption(billId, false, 0);
    }

    function testRequestEarlyRedemptionRevertsIfPendingExists() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        bill.requestEarlyRedemption(billId, false, 0);

        vm.prank(owner);
        vm.expectRevert(DiscountBillERC5095Upgradeable.PendingRequestExists.selector);
        bill.requestEarlyRedemption(billId, false, 0);
    }

    function testPreviewEarlyRedemption() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        (uint256 breakFee, uint256 accruedInterest, uint256 payoutAmount, uint256 daysRemaining) =
            bill.previewEarlyRedemption(billId, false, 0);

        assertTrue(breakFee > 0);
        assertTrue(accruedInterest > 0);
        assertTrue(payoutAmount > 0);
        assertEq(daysRemaining, 0); // Less than 1 day remaining
    }

    function testBreakFeeDecreasesOverTime() public {
        (uint256 billId,,) = _issueDefault(address(token));

        // Check break fee at start (should be max)
        (uint256 earlyBreakFee,,,) = bill.previewEarlyRedemption(billId, false, 0);

        // Move forward 50% of term
        vm.warp(block.timestamp + 12 hours);

        // Check break fee midway (should be ~50% of original)
        (uint256 midBreakFee,,,) = bill.previewEarlyRedemption(billId, false, 0);

        // Break fee should decrease over time
        assertTrue(midBreakFee < earlyBreakFee);
    }

    // ========== EARLY REDEMPTION APPROVAL TESTS ==========

    function testApproveEarlyRedemptionFull() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, false, 0);

        DiscountBillERC5095Upgradeable.EarlyRedemptionRequest memory req =
            bill.getEarlyRedemptionRequest(requestId);
        uint256 expectedPayout = req.payoutAmount;

        uint256 depositWalletBefore = token.balanceOf(depositWallet);

        vm.prank(admin);
        bill.approveEarlyRedemption(requestId);

        // Check payout was made
        assertEq(token.balanceOf(depositWallet), depositWalletBefore + expectedPayout);

        // Check bill was burned
        vm.expectRevert();
        bill.ownerOf(billId);

        // Check request status
        req = bill.getEarlyRedemptionRequest(requestId);
        assertEq(uint256(req.status), uint256(DiscountBillERC5095Upgradeable.RedemptionStatus.Executed));
    }

    function testApproveEarlyRedemptionPartial() public {
        (uint256 billId, uint256 redemptionValue,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory infoBefore = bill.getBillInfo(billId);

        vm.warp(block.timestamp + 12 hours);

        uint256 partialAmount = redemptionValue / 2;
        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, true, partialAmount);

        vm.prank(admin);
        bill.approveEarlyRedemption(requestId);

        // Bill should still exist
        assertEq(bill.ownerOf(billId), owner);

        // Bill value should be reduced
        IDiscountBill.BillInfo memory infoAfter = bill.getBillInfo(billId);
        assertTrue(infoAfter.redemptionValue < infoBefore.redemptionValue);
        assertTrue(infoAfter.principal < infoBefore.principal);
    }

    function testApproveEarlyRedemptionRevertsIfNotOperator() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, false, 0);

        vm.prank(owner);
        vm.expectRevert();
        bill.approveEarlyRedemption(requestId);
    }

    function testApproveEarlyRedemptionRevertsIfOwnershipChanged() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, false, 0);

        // Transfer ownership
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        bill.transferFrom(owner, newOwner, billId);

        // Should revert because requester no longer owns bill
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.NotOwner.selector);
        bill.approveEarlyRedemption(requestId);
    }

    // ========== EARLY REDEMPTION REJECTION TESTS ==========

    function testRejectEarlyRedemption() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, false, 0);

        vm.prank(admin);
        bill.rejectEarlyRedemption(requestId, "Insufficient liquidity");

        DiscountBillERC5095Upgradeable.EarlyRedemptionRequest memory req =
            bill.getEarlyRedemptionRequest(requestId);
        assertEq(uint256(req.status), uint256(DiscountBillERC5095Upgradeable.RedemptionStatus.Rejected));
    }

    function testCancelEarlyRedemption() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, false, 0);

        vm.prank(owner);
        bill.cancelEarlyRedemption(requestId);

        DiscountBillERC5095Upgradeable.EarlyRedemptionRequest memory req =
            bill.getEarlyRedemptionRequest(requestId);
        assertEq(uint256(req.status), uint256(DiscountBillERC5095Upgradeable.RedemptionStatus.Rejected));
    }

    function testCancelEarlyRedemptionRevertsIfNotRequester() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, false, 0);

        vm.prank(depositor);
        vm.expectRevert(DiscountBillERC5095Upgradeable.NotRequester.selector);
        bill.cancelEarlyRedemption(requestId);
    }

    function testCanRequestAgainAfterRejection() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, false, 0);

        vm.prank(admin);
        bill.rejectEarlyRedemption(requestId, "Rejected");

        // Should be able to request again
        vm.prank(owner);
        uint256 newRequestId = bill.requestEarlyRedemption(billId, false, 0);
        assertTrue(newRequestId > requestId);
    }

    function testGetBillRequests() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.warp(block.timestamp + 12 hours);

        vm.prank(owner);
        uint256 req1 = bill.requestEarlyRedemption(billId, false, 0);

        vm.prank(admin);
        bill.rejectEarlyRedemption(req1, "Rejected");

        vm.prank(owner);
        uint256 req2 = bill.requestEarlyRedemption(billId, false, 0);

        uint256[] memory requests = bill.getBillRequests(billId);
        assertEq(requests.length, 2);
        assertEq(requests[0], req1);
        assertEq(requests[1], req2);
    }

    // ========== DEPOSIT WALLET UPDATE TESTS ==========

    function testUpdateDepositWallet() public {
        (uint256 billId,,) = _issueDefault(address(token));

        address newWallet = makeAddr("newWallet");

        vm.prank(owner);
        bill.updateDepositWallet(billId, newWallet);

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        assertEq(info.depositWallet, newWallet);
    }

    function testUpdateDepositWalletRevertsIfNotOwner() public {
        (uint256 billId,,) = _issueDefault(address(token));

        address newWallet = makeAddr("newWallet");

        vm.prank(depositor);
        vm.expectRevert(DiscountBillERC5095Upgradeable.NotOwner.selector);
        bill.updateDepositWallet(billId, newWallet);
    }

    function testUpdateDepositWalletRevertsIfZeroAddress() public {
        (uint256 billId,,) = _issueDefault(address(token));

        vm.prank(owner);
        vm.expectRevert(DiscountBillERC5095Upgradeable.ZeroAddress.selector);
        bill.updateDepositWallet(billId, address(0));
    }

    function testUpdateDepositWalletRevertsIfNotCompliant() public {
        (uint256 billId,,) = _issueDefault(address(token));

        address blockedWallet = makeAddr("blockedWallet");
        compliance.setBlocked(blockedWallet, true);

        vm.prank(owner);
        vm.expectRevert(DiscountBillERC5095Upgradeable.ComplianceBlocked.selector);
        bill.updateDepositWallet(billId, blockedWallet);
    }

    function testRedemptionUsesUpdatedDepositWallet() public {
        (uint256 billId, uint256 finalAmount, uint256 commission) = _issueDefault(address(token));

        address newWallet = makeAddr("newWallet");
        vm.prank(owner);
        bill.updateDepositWallet(billId, newWallet);

        vm.warp(block.timestamp + 2 days);

        uint256 newWalletBefore = token.balanceOf(newWallet);
        uint256 oldWalletBefore = token.balanceOf(depositWallet);

        vm.prank(owner);
        bill.redeem(billId);

        // New wallet should receive funds
        assertEq(token.balanceOf(newWallet), newWalletBefore + finalAmount - commission);
        // Old wallet unchanged
        assertEq(token.balanceOf(depositWallet), oldWalletBefore);
    }

    // ========== BREAK FEE CALCULATION VERIFICATION ==========

    function testBreakFeeCalculationProRata() public {
        // Issue a 90-day bill
        vm.prank(admin);
        uint256 billId = bill.issue(
            owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 36_500, 90
        );

        // Get the bill info to find the issuance time
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        uint256 issuanceTime = info.issuance;

        // At day 0: full break fee (90 days remaining)
        (uint256 breakFeeDay0,,,uint256 daysRemainingDay0) = bill.previewEarlyRedemption(billId, false, 0);
        assertEq(daysRemainingDay0, 90, "Should have 90 days remaining at start");

        // Move to day 30 (1/3 elapsed, 2/3 remaining = 60 days)
        vm.warp(issuanceTime + 30 days);
        (uint256 breakFeeDay30,,,uint256 daysRemainingDay30) = bill.previewEarlyRedemption(billId, false, 0);
        assertEq(daysRemainingDay30, 60, "Should have 60 days remaining at day 30");

        // Move to day 60 (2/3 elapsed, 1/3 remaining = 30 days)
        vm.warp(issuanceTime + 60 days);
        (uint256 breakFeeDay60,,,uint256 daysRemainingDay60) = bill.previewEarlyRedemption(billId, false, 0);
        assertEq(daysRemainingDay60, 30, "Should have 30 days remaining at day 60");

        // Break fee should decrease: day0 > day30 > day60
        assertTrue(breakFeeDay0 > breakFeeDay30, "Break fee should decrease from day 0 to day 30");
        assertTrue(breakFeeDay30 > breakFeeDay60, "Break fee should decrease from day 30 to day 60");

        // Approximately: day30 should be ~2/3 of day0
        // Allow some rounding tolerance (5% margin)
        uint256 expected30 = (breakFeeDay0 * 2) / 3;
        uint256 tolerance = breakFeeDay0 / 20; // 5% tolerance
        assertTrue(
            breakFeeDay30 >= (expected30 > tolerance ? expected30 - tolerance : 0) &&
            breakFeeDay30 <= expected30 + tolerance,
            "Day 30 break fee not within tolerance"
        );
    }

    function testAccruedInterestCalculationProRata() public {
        // Issue a 90-day bill at 10% APY
        vm.prank(admin);
        uint256 billId = bill.issue(
            owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 10_000, 90
        );

        // At day 0: no accrued interest
        (, uint256 accruedDay0,,) = bill.previewEarlyRedemption(billId, false, 0);
        assertEq(accruedDay0, 0);

        // Move to day 45 (50% of term)
        vm.warp(block.timestamp + 45 days);
        (, uint256 accruedDay45,,) = bill.previewEarlyRedemption(billId, false, 0);

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        uint256 totalInterest = info.redemptionValue - info.principal;

        // Accrued should be ~50% of total
        assertTrue(accruedDay45 > 0);
        uint256 expectedAccrued = totalInterest / 2;
        assertTrue(accruedDay45 >= expectedAccrued - 1e15 && accruedDay45 <= expectedAccrued + 1e15);
    }

    // ========== DEPOSIT CAP TESTS ==========

    function testSetMaxDepositAmountByAdmin() public {
        vm.prank(admin);
        bill.setMaxDepositAmount(address(token), 500 ether);
        assertEq(bill.maxDepositAmount(address(token)), 500 ether);
    }

    function testSetMaxDepositAmountRevertsFromNonAdmin() public {
        vm.prank(depositor);
        vm.expectRevert();
        bill.setMaxDepositAmount(address(token), 500 ether);

        vm.prank(issuer);
        vm.expectRevert();
        bill.setMaxDepositAmount(address(token), 500 ether);
    }

    function testSetMaxDepositAmountEmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit IDiscountBill.MaxDepositAmountSet(address(token), 500 ether);
        bill.setMaxDepositAmount(address(token), 500 ether);
    }

    function testIssueRevertsBeyondDepositCap() public {
        vm.prank(admin);
        bill.setMaxDepositAmount(address(token), 500 ether);

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.ExceedsDepositCap.selector);
        bill.issue(owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 36_500, 1);
    }

    function testIssueSucceedsAtExactCap() public {
        vm.prank(admin);
        bill.setMaxDepositAmount(address(token), PRINCIPAL);

        (uint256 billId,,) = _issueDefault(address(token));
        assertEq(bill.ownerOf(billId), owner);
    }

    function testZeroCapMeansUnlimited() public {
        assertEq(bill.maxDepositAmount(address(token)), 0);
        (uint256 billId,,) = _issueDefault(address(token));
        assertEq(bill.ownerOf(billId), owner);
    }

    function testCapCanBeRemovedBySettingToZero() public {
        vm.prank(admin);
        bill.setMaxDepositAmount(address(token), 500 ether);

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.ExceedsDepositCap.selector);
        bill.issue(owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 36_500, 1);

        vm.prank(admin);
        bill.setMaxDepositAmount(address(token), 0);

        (uint256 billId,,) = _issueDefault(address(token));
        assertEq(bill.ownerOf(billId), owner);
    }

    // ========== PAUSE TESTS ==========

    function testIssueRevertsWhenPaused() public {
        vm.prank(admin);
        bill.pause();

        vm.prank(admin);
        vm.expectRevert();
        bill.issue(owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 36_500, 1);
    }

    function testPauseAndUnpause() public {
        vm.prank(admin);
        bill.pause();
        assertTrue(bill.paused());

        vm.prank(admin);
        bill.unpause();
        assertFalse(bill.paused());
    }

    // ========== NFT METADATA TESTS ==========

    function testSetBaseURIAndTokenURI() public {
        (uint256 billId,,) = _issueDefault(address(token));

        // Set base URI
        vm.prank(admin);
        bill.setBaseURI("https://api.cryptodeposit.org/nft/1/");

        string memory uri = bill.tokenURI(billId);
        assertEq(uri, string(abi.encodePacked("https://api.cryptodeposit.org/nft/1/", vm.toString(billId))));
    }

    function testSetBaseURIRevertsForNonAdmin() public {
        vm.prank(owner);
        vm.expectRevert();
        bill.setBaseURI("https://example.com/");
    }

    function testContractURI() public {
        // Initially empty
        assertEq(bill.contractURI(), "");

        vm.prank(admin);
        bill.setContractURI("https://api.cryptodeposit.org/nft/collection.json");
        assertEq(bill.contractURI(), "https://api.cryptodeposit.org/nft/collection.json");
    }

    function testSetContractURIRevertsForNonAdmin() public {
        vm.prank(owner);
        vm.expectRevert();
        bill.setContractURI("https://example.com/collection.json");
    }

    // ========== ESCHEATMENT TESTS ==========

    function testSetDefaultClaimWindow() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(365 days); // 1 year

        assertEq(bill.defaultClaimWindow(), 365 days);
    }

    function testSetDefaultClaimWindowEmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit DiscountBillERC5095Upgradeable.DefaultClaimWindowUpdated(0, 365 days);
        bill.setDefaultClaimWindow(365 days);
    }

    function testSetDefaultClaimWindowRevertsUnder30Days() public {
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.InvalidClaimWindow.selector);
        bill.setDefaultClaimWindow(29 days);
    }

    function testSetDefaultClaimWindowAllowsZero() public {
        // First set a window
        vm.prank(admin);
        bill.setDefaultClaimWindow(365 days);

        // Zero disables escheatment
        vm.prank(admin);
        bill.setDefaultClaimWindow(0);
        assertEq(bill.defaultClaimWindow(), 0);
    }

    function testSetDefaultClaimWindowRevertsForNonAdmin() public {
        vm.prank(owner);
        vm.expectRevert();
        bill.setDefaultClaimWindow(365 days);
    }

    function testClaimDeadlineSetOnIssueWhenDefaultConfigured() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(365 days);

        (uint256 billId,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        uint256 deadline = bill.getClaimDeadline(billId);
        assertEq(deadline, info.maturity + 365 days);
    }

    function testClaimDeadlineZeroWhenNoDefault() public {
        // No default claim window set
        (uint256 billId,,) = _issueDefault(address(token));
        assertEq(bill.getClaimDeadline(billId), 0);
    }

    function testSetBillClaimDeadlineOverride() public {
        (uint256 billId,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        uint256 customDeadline = info.maturity + 60 days;
        vm.prank(admin);
        bill.setBillClaimDeadline(billId, customDeadline);

        assertEq(bill.getClaimDeadline(billId), customDeadline);
    }

    function testSetBillClaimDeadlineRevertsIfTooSoon() public {
        (uint256 billId,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Less than maturity + 30 days
        uint256 tooSoon = info.maturity + 20 days;
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.InvalidClaimWindow.selector);
        bill.setBillClaimDeadline(billId, tooSoon);
    }

    function testSetBillClaimDeadlineResetToDefault() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(365 days);

        (uint256 billId,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Override
        vm.prank(admin);
        bill.setBillClaimDeadline(billId, info.maturity + 60 days);
        assertEq(bill.getClaimDeadline(billId), info.maturity + 60 days);

        // Reset to default (0)
        vm.prank(admin);
        bill.setBillClaimDeadline(billId, 0);
        assertEq(bill.getClaimDeadline(billId), info.maturity + 365 days);
    }

    function testIsExpiredReturnsFalseBeforeDeadline() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        (uint256 billId,,) = _issueDefault(address(token));

        // Before maturity
        assertFalse(bill.isExpired(billId));

        // After maturity but before deadline
        vm.warp(block.timestamp + 2 days); // matured (1-day bill)
        assertFalse(bill.isExpired(billId));

        // At maturity + 29 days (still within window)
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        vm.warp(info.maturity + 29 days);
        assertFalse(bill.isExpired(billId));
    }

    function testIsExpiredReturnsTrueAfterDeadline() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        (uint256 billId,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Past deadline
        vm.warp(info.maturity + 31 days);
        assertTrue(bill.isExpired(billId));
    }

    function testIsExpiredReturnsFalseWithNoEscheatment() public {
        // No default claim window
        (uint256 billId,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        vm.warp(info.maturity + 10000 days);
        assertFalse(bill.isExpired(billId));
    }

    function testBurnExpired() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        (uint256 billId, uint256 redemptionValue,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Warp past claim deadline
        vm.warp(info.maturity + 31 days);
        assertTrue(bill.isExpired(billId));

        uint256 issuerBefore = token.balanceOf(issuer);

        vm.prank(admin);
        bill.burnExpired(billId);

        // Bill should be burned
        vm.expectRevert();
        bill.ownerOf(billId);

        // Bill data zeroed
        assertEq(bill.redeemableValue(billId), 0);
        assertTrue(bill.billInvalidated(billId));

        // Funds stay with issuer (no treasury in this test)
        assertEq(token.balanceOf(issuer), issuerBefore);
    }

    function testBurnExpiredRevertsIfNotExpired() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        (uint256 billId,,) = _issueDefault(address(token));

        // Only matured, not expired
        vm.warp(block.timestamp + 2 days);
        assertFalse(bill.isExpired(billId));

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.NotExpired.selector);
        bill.burnExpired(billId);
    }

    function testBurnExpiredRevertsIfAlreadyRedeemed() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        (uint256 billId,,) = _issueDefault(address(token));

        // Redeem first
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        bill.redeem(billId);

        // Now it's redeemed — isExpired returns false (redemptionValue == 0)
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        vm.warp(info.maturity + 31 days);
        assertFalse(bill.isExpired(billId));

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.NotExpired.selector);
        bill.burnExpired(billId);
    }

    function testBurnExpiredRevertsForNonOperator() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        (uint256 billId,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        vm.warp(info.maturity + 31 days);

        vm.prank(owner);
        vm.expectRevert();
        bill.burnExpired(billId);
    }

    function testBatchBurnExpired() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        // Issue 3 bills
        (uint256 id1,,) = _issueDefault(address(token));
        (uint256 id2,,) = _issueDefault(address(token));
        (uint256 id3,,) = _issueDefault(address(token));

        IDiscountBill.BillInfo memory info = bill.getBillInfo(id1);
        vm.warp(info.maturity + 31 days);

        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;

        vm.prank(admin);
        bill.batchBurnExpired(ids);

        // All burned
        for (uint256 i = 0; i < ids.length; i++) {
            vm.expectRevert();
            bill.ownerOf(ids[i]);
            assertEq(bill.redeemableValue(ids[i]), 0);
            assertTrue(bill.billInvalidated(ids[i]));
        }
    }

    function testBatchBurnExpiredRevertsIfOneNotExpired() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        (uint256 id1,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info1 = bill.getBillInfo(id1);

        // Issue second bill later (different maturity)
        vm.warp(block.timestamp + 15 days);
        (uint256 id2,,) = _issueDefault(address(token));

        // Warp so id1 is expired but id2 is not
        vm.warp(info1.maturity + 31 days);
        assertTrue(bill.isExpired(id1));
        assertFalse(bill.isExpired(id2));

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.NotExpired.selector);
        bill.batchBurnExpired(ids);
    }

    function testBurnExpiredEmitsEvent() public {
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        (uint256 billId, uint256 redemptionValue,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        vm.warp(info.maturity + 31 days);

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit DiscountBillERC5095Upgradeable.BillExpiredAndBurned(billId, owner, redemptionValue, 0, issuer);
        bill.burnExpired(billId);
    }

    // ========== TREASURY-PATH ESCHEATMENT TESTS ==========

    // Helper: deploy treasury and wire to bill contract
    function _setupTreasury() internal returns (TreasuryUpgradeable) {
        TreasuryUpgradeable treasuryImpl = new TreasuryUpgradeable();
        TreasuryUpgradeable treasuryProxy = TreasuryUpgradeable(
            address(
                new ERC1967Proxy(
                    address(treasuryImpl),
                    abi.encodeCall(TreasuryUpgradeable.initialize, (admin))
                )
            )
        );
        bytes32 depositManagerRole = treasuryProxy.DEPOSIT_MANAGER_ROLE();
        vm.prank(admin);
        treasuryProxy.grantRole(depositManagerRole, address(bill));
        vm.prank(admin);
        bill.setTreasury(address(treasuryProxy));
        vm.prank(depositor);
        token.approve(address(bill), type(uint256).max);
        return treasuryProxy;
    }

    function testBurnExpiredWithTreasuryClearsLiability() public {
        TreasuryUpgradeable treasuryProxy = _setupTreasury();

        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        vm.prank(admin);
        uint256 billId = bill.issue(
            owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 36_500, 1
        );
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        uint256 liabBefore = treasuryProxy.depositLiabilities(address(token));
        uint256 claimsBefore = treasuryProxy.depositClaims(address(token));
        assertTrue(liabBefore > 0);

        vm.warp(info.maturity + 31 days);
        assertTrue(bill.isExpired(billId));

        vm.prank(admin);
        bill.burnExpired(billId);

        // depositLiabilities reduced by full liability (principal + interest)
        assertEq(treasuryProxy.depositLiabilities(address(token)), liabBefore - info.redemptionValue);
        // depositClaims reduced by principal only
        assertEq(treasuryProxy.depositClaims(address(token)), claimsBefore - info.principal);
        // protocolRevenue must NOT increase (expired deposits are not realized yield)
        assertEq(treasuryProxy.protocolRevenue(address(token)), 0);
        // ownedCapital tracks the principal (real funded capital)
        assertEq(treasuryProxy.ownedCapital(address(token)), info.principal);
        // Tokens still in treasury
        assertEq(token.balanceOf(address(treasuryProxy)), PRINCIPAL);

        vm.expectRevert();
        bill.ownerOf(billId);
    }

    function testBurnExpiredWithTreasuryExternalFundingSource() public {
        TreasuryUpgradeable treasuryProxy = _setupTreasury();

        // Create series with custom fundingSource
        address sponsor = makeAddr("sponsor");
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Sponsored Airdrop", address(token), 5 ether, 10_000, 7, 30, 10, sponsor
        );

        address recipient = makeAddr("recipient");
        vm.prank(admin);
        uint256 billId = bill.issueFromSeries(seriesId, recipient, depositor, depositWallet, introducingWallet);
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        uint256 liabBefore = treasuryProxy.depositLiabilities(address(token));
        uint256 sponsorBefore = token.balanceOf(sponsor);

        vm.warp(info.maturity + 31 days);
        assertTrue(bill.isExpired(billId));

        vm.prank(admin);
        bill.burnExpired(billId);

        // Accounting fully cleared
        assertEq(treasuryProxy.depositLiabilities(address(token)), liabBefore - info.redemptionValue);
        // Only principal transferred to sponsor (interest was never funded)
        assertEq(token.balanceOf(sponsor), sponsorBefore + info.principal);
        // protocolRevenue untouched, ownedCapital = 0 (principal was disbursed)
        assertEq(treasuryProxy.protocolRevenue(address(token)), 0);
        assertEq(treasuryProxy.ownedCapital(address(token)), 0);

        vm.expectRevert();
        bill.ownerOf(billId);
    }

    function testBurnExpiredNoTreasuryExternalFundingSource() public {
        // No treasury — test issuer-to-fundingSource transfer
        address sponsor = makeAddr("sponsor");
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "No-Treasury Airdrop", address(token), 5 ether, 10_000, 7, 30, 10, sponsor
        );

        address recipient = makeAddr("recipient");
        vm.prank(admin);
        uint256 billId = bill.issueFromSeries(seriesId, recipient, depositor, depositWallet, introducingWallet);
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        uint256 issuerBefore = token.balanceOf(issuer);
        uint256 sponsorBefore = token.balanceOf(sponsor);

        vm.warp(info.maturity + 31 days);

        vm.prank(admin);
        bill.burnExpired(billId);

        // Issuer transferred principal to sponsor (only principal, not full liability)
        assertEq(token.balanceOf(sponsor), sponsorBefore + info.principal);
        assertEq(token.balanceOf(issuer), issuerBefore - info.principal);

        vm.expectRevert();
        bill.ownerOf(billId);
    }

    // ========== BILL SERIES TESTS ==========

    function testCreateSeries() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "USDT $5 Airdrop",
            address(token),
            5 ether,      // principalPerBill
            10_000,       // 100% APY
            7,            // 7 days
            30,           // 30-day claim window
            100,          // max 100 bills
            address(0)    // treasury as funding source
        );

        assertEq(seriesId, 1);
        assertEq(bill.seriesCount(), 1);

        DiscountBillERC5095Upgradeable.BillSeries memory s = bill.getSeriesInfo(seriesId);
        assertEq(s.principalPerBill, 5 ether);
        assertEq(s.annualRateBps, 10_000);
        assertEq(s.durationInDays, 7);
        assertEq(s.claimWindowDays, 30);
        assertEq(s.maxBills, 100);
        assertEq(s.issuedCount, 0);
        assertTrue(s.active);
    }

    function testCreateSeriesEmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit DiscountBillERC5095Upgradeable.SeriesCreated(1, "Airdrop", address(token), 5 ether, 100);
        bill.createSeries("Airdrop", address(token), 5 ether, 10_000, 7, 30, 100, address(0));
    }

    function testCreateSeriesRevertsForNonAdmin() public {
        vm.prank(owner);
        vm.expectRevert();
        bill.createSeries("Airdrop", address(token), 5 ether, 10_000, 7, 30, 100, address(0));
    }

    function testCreateSeriesRevertsOnBadParams() public {
        // Zero token
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.ZeroAddress.selector);
        bill.createSeries("X", address(0), 5 ether, 10_000, 7, 30, 100, address(0));

        // Zero principal
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.InvalidAmount.selector);
        bill.createSeries("X", address(token), 0, 10_000, 7, 30, 100, address(0));

        // Invalid rate
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.InvalidRate.selector);
        bill.createSeries("X", address(token), 5 ether, 0, 7, 30, 100, address(0));

        // Zero duration
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.InvalidDuration.selector);
        bill.createSeries("X", address(token), 5 ether, 10_000, 0, 30, 100, address(0));

        // Claim window < 30 days
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.InvalidClaimWindow.selector);
        bill.createSeries("X", address(token), 5 ether, 10_000, 7, 29, 100, address(0));
    }

    function testIssueFromSeries() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), 5 ether, 10_000, 7, 30, 10, address(0)
        );

        address recipient = makeAddr("recipient");

        vm.prank(admin);
        uint256 billId = bill.issueFromSeries(seriesId, recipient, depositor, depositWallet, introducingWallet);

        // Bill exists and is owned by recipient
        assertEq(bill.ownerOf(billId), recipient);

        // Bill has series parameters
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);
        assertEq(info.principal, 5 ether);
        assertEq(info.token, address(token));

        // Bill tagged to series
        assertEq(bill.billSeries(billId), seriesId);

        // Series issued count updated
        DiscountBillERC5095Upgradeable.BillSeries memory s = bill.getSeriesInfo(seriesId);
        assertEq(s.issuedCount, 1);

        // Claim deadline set from series claimWindowDays
        uint256 deadline = bill.getClaimDeadline(billId);
        assertEq(deadline, info.maturity + 30 days);
    }

    function testIssueFromSeriesEmitsEvent() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), 5 ether, 10_000, 7, 30, 10, address(0)
        );

        address recipient = makeAddr("recipient");

        vm.prank(admin);
        // SeriesBillIssued(seriesId, billId, recipient)
        vm.expectEmit(true, true, true, false);
        emit DiscountBillERC5095Upgradeable.SeriesBillIssued(seriesId, 1, recipient);
        bill.issueFromSeries(seriesId, recipient, depositor, depositWallet, introducingWallet);
    }

    function testIssueFromSeriesExhausted() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Small", address(token), 5 ether, 10_000, 7, 30, 2, address(0)
        );

        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");
        address r3 = makeAddr("r3");

        vm.prank(admin);
        bill.issueFromSeries(seriesId, r1, depositor, depositWallet, introducingWallet);

        vm.prank(admin);
        bill.issueFromSeries(seriesId, r2, depositor, depositWallet, introducingWallet);

        // Third should revert — max 2 bills
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.SeriesExhausted.selector);
        bill.issueFromSeries(seriesId, r3, depositor, depositWallet, introducingWallet);
    }

    function testIssueFromSeriesUnlimited() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Unlimited", address(token), 5 ether, 10_000, 7, 30, 0, address(0) // maxBills = 0 = unlimited
        );

        // Issue several — should all succeed
        for (uint256 i = 0; i < 5; i++) {
            address r = makeAddr(string(abi.encodePacked("r", vm.toString(i))));
            vm.prank(admin);
            bill.issueFromSeries(seriesId, r, depositor, depositWallet, introducingWallet);
        }

        DiscountBillERC5095Upgradeable.BillSeries memory s = bill.getSeriesInfo(seriesId);
        assertEq(s.issuedCount, 5);
    }

    function testDeactivateSeries() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), 5 ether, 10_000, 7, 30, 100, address(0)
        );

        vm.prank(admin);
        bill.deactivateSeries(seriesId);

        DiscountBillERC5095Upgradeable.BillSeries memory s = bill.getSeriesInfo(seriesId);
        assertFalse(s.active);

        // Can't issue from deactivated series
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.SeriesNotFound.selector);
        bill.issueFromSeries(seriesId, owner, depositor, depositWallet, introducingWallet);
    }

    function testDeactivateSeriesEmitsEvent() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), 5 ether, 10_000, 7, 30, 100, address(0)
        );

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit DiscountBillERC5095Upgradeable.SeriesDeactivated(seriesId);
        bill.deactivateSeries(seriesId);
    }

    function testDeactivateSeriesRevertsForNonAdmin() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), 5 ether, 10_000, 7, 30, 100, address(0)
        );

        vm.prank(owner);
        vm.expectRevert();
        bill.deactivateSeries(seriesId);
    }

    function testDeactivateSeriesRevertsInvalidId() public {
        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.SeriesNotFound.selector);
        bill.deactivateSeries(0);

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.SeriesNotFound.selector);
        bill.deactivateSeries(999);
    }

    function testIssueFromSeriesRevertsForNonOperator() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), 5 ether, 10_000, 7, 30, 100, address(0)
        );

        vm.prank(owner);
        vm.expectRevert();
        bill.issueFromSeries(seriesId, owner, depositor, depositWallet, introducingWallet);
    }

    function testIssueFromSeriesRevertsWhenPaused() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), 5 ether, 10_000, 7, 30, 100, address(0)
        );

        vm.prank(admin);
        bill.pause();

        vm.prank(admin);
        vm.expectRevert();
        bill.issueFromSeries(seriesId, owner, depositor, depositWallet, introducingWallet);
    }

    function testSeriesBillEscheatment() public {
        // Create series with 30-day claim window
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), 5 ether, 10_000, 7, 30, 10, address(0)
        );

        address recipient = makeAddr("recipient");
        vm.prank(admin);
        uint256 billId = bill.issueFromSeries(seriesId, recipient, depositor, depositWallet, introducingWallet);

        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Not expired before deadline
        vm.warp(info.maturity + 29 days);
        assertFalse(bill.isExpired(billId));

        // Expired after deadline
        vm.warp(info.maturity + 31 days);
        assertTrue(bill.isExpired(billId));

        // Can burn
        vm.prank(admin);
        bill.burnExpired(billId);

        vm.expectRevert();
        bill.ownerOf(billId);
    }

    function testMultipleSeries() public {
        vm.prank(admin);
        uint256 s1 = bill.createSeries("S1", address(token), 5 ether, 10_000, 7, 30, 100, address(0));
        vm.prank(admin);
        uint256 s2 = bill.createSeries("S2", address(token), 10 ether, 5_000, 30, 60, 50, address(0));

        assertEq(s1, 1);
        assertEq(s2, 2);
        assertEq(bill.seriesCount(), 2);

        // Issue from each
        vm.prank(admin);
        uint256 b1 = bill.issueFromSeries(s1, owner, depositor, depositWallet, introducingWallet);
        vm.prank(admin);
        uint256 b2 = bill.issueFromSeries(s2, owner, depositor, depositWallet, introducingWallet);

        assertEq(bill.billSeries(b1), s1);
        assertEq(bill.billSeries(b2), s2);

        IDiscountBill.BillInfo memory info1 = bill.getBillInfo(b1);
        IDiscountBill.BillInfo memory info2 = bill.getBillInfo(b2);
        assertEq(info1.principal, 5 ether);
        assertEq(info2.principal, 10 ether);
    }

    function testGetSeriesInfoRevertsInvalidId() public {
        vm.expectRevert(DiscountBillERC5095Upgradeable.SeriesNotFound.selector);
        bill.getSeriesInfo(0);

        vm.expectRevert(DiscountBillERC5095Upgradeable.SeriesNotFound.selector);
        bill.getSeriesInfo(1);
    }

    // ========== REGRESSION: SERIES MERGE PROTECTION ==========

    function testSeriesBillCannotMergeWithStandard() public {
        // Issue a series bill
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), PRINCIPAL, 36_500, 90, 30, 10, address(0)
        );
        vm.prank(admin);
        uint256 seriesBillId = bill.issueFromSeries(seriesId, owner, depositor, depositWallet, introducingWallet);

        // Issue a standard bill (same params for compatibility)
        vm.prank(admin);
        uint256 stdBillId = bill.issue(
            owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 36_500, 90
        );

        uint256[] memory ids = new uint256[](2);
        ids[0] = seriesBillId;
        ids[1] = stdBillId;

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.SeriesBillCannotMerge.selector);
        bill.merge(ids, 36_500);
    }

    function testStandardBillCannotMergeWithSeries() public {
        vm.prank(admin);
        uint256 seriesId = bill.createSeries(
            "Airdrop", address(token), PRINCIPAL, 36_500, 90, 30, 10, address(0)
        );
        vm.prank(admin);
        uint256 seriesBillId = bill.issueFromSeries(seriesId, owner, depositor, depositWallet, introducingWallet);

        vm.prank(admin);
        uint256 stdBillId = bill.issue(
            owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 36_500, 90
        );

        // Standard first, series second — series check still catches it
        uint256[] memory ids = new uint256[](2);
        ids[0] = stdBillId;
        ids[1] = seriesBillId;

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.SeriesBillCannotMerge.selector);
        bill.merge(ids, 36_500);
    }

    // ========== REGRESSION: RETROACTIVE CLAIM WINDOW ==========

    function testLegacyBillNotRetroactivelyBurnable() public {
        // Issue a bill BEFORE any claim window is configured
        (uint256 billId,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Bill matures
        vm.warp(info.maturity + 1);
        assertTrue(bill.isMature(billId));

        // Now admin sets default claim window (simulates post-upgrade config)
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        // Legacy bill should NOT be subject to the new window
        assertEq(bill.getClaimDeadline(billId), 0, "Legacy bill should have no claim deadline");
        assertFalse(bill.isExpired(billId), "Legacy bill must not be expired");

        // Even after 100 days past maturity — still not burnable
        vm.warp(info.maturity + 100 days);
        assertFalse(bill.isExpired(billId));

        vm.prank(admin);
        vm.expectRevert(DiscountBillERC5095Upgradeable.NotExpired.selector);
        bill.burnExpired(billId);
    }

    function testNewBillSubjectToClaimWindow() public {
        // Set claim window first
        vm.prank(admin);
        bill.setDefaultClaimWindow(30 days);

        // Issue a bill AFTER window is configured
        (uint256 billId,,) = _issueDefault(address(token));
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // This bill SHOULD have a claim deadline
        assertEq(bill.getClaimDeadline(billId), info.maturity + 30 days);

        // After deadline, it IS burnable
        vm.warp(info.maturity + 31 days);
        assertTrue(bill.isExpired(billId));
    }

    // ========== REGRESSION: EARLY REDEMPTION REVENUE ==========

    function testEarlyRedemptionDoesNotOverstateRevenue() public {
        TreasuryUpgradeable treasuryProxy = _setupTreasury();

        // Issue a 90-day bill at 10% APY
        vm.prank(admin);
        uint256 billId = bill.issue(
            owner, depositor, depositWallet, introducingWallet, address(token), PRINCIPAL, 10_000, 90
        );
        IDiscountBill.BillInfo memory info = bill.getBillInfo(billId);

        // Move to day 1 (very early — most interest unaccrued)
        vm.warp(block.timestamp + 1 days);

        // Request early redemption
        vm.prank(owner);
        uint256 requestId = bill.requestEarlyRedemption(billId, false, 0);

        DiscountBillERC5095Upgradeable.EarlyRedemptionRequest memory req =
            bill.getEarlyRedemptionRequest(requestId);

        // Approve early redemption
        vm.prank(admin);
        bill.approveEarlyRedemption(requestId);

        // protocolRevenue must be zero — break fee goes to ownedCapital, not revenue
        assertEq(treasuryProxy.protocolRevenue(address(token)), 0,
            "protocolRevenue must not increase from early redemption");

        // ownedCapital should hold the retained principal
        assertTrue(treasuryProxy.ownedCapital(address(token)) > 0 || req.breakFee == 0,
            "retained principal should be in ownedCapital");

        // Treasury token balance must be >= ownedCapital (cash actually there)
        assertTrue(
            token.balanceOf(address(treasuryProxy)) >= treasuryProxy.ownedCapital(address(token)),
            "ownedCapital cannot exceed actual treasury balance"
        );
    }
}

// ========== BATCH HELPER TESTS ==========

import {DiscountBillBatchHelper} from "../src/DiscountBillBatchHelper.sol";

contract DiscountBillBatchHelperTest is Test {
    DiscountBillERC5095Upgradeable private bill;
    DiscountBillBatchHelper private batchHelper;
    ComplianceRegistryMock private compliance;
    TravelRuleRegistryMock private travel;
    MockERC20 private token;

    address private admin = makeAddr("admin");
    address private issuer = makeAddr("issuer");
    address private depositor = makeAddr("depositor");
    address private owner1 = makeAddr("owner1");
    address private depositWallet = makeAddr("depositWallet");
    address private introducingWallet = makeAddr("introducingWallet");
    uint256 private constant PRINCIPAL = 1_000 ether;

    function setUp() public {
        compliance = new ComplianceRegistryMock();
        travel = new TravelRuleRegistryMock();
        token = new MockERC20();
        DiscountBillERC5095Upgradeable impl = new DiscountBillERC5095Upgradeable();
        bill = DiscountBillERC5095Upgradeable(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(DiscountBillERC5095Upgradeable.initialize, (admin, issuer, compliance, travel))
                )
            )
        );

        BillTokenFactory factory = new BillTokenFactory();
        vm.prank(admin);
        bill.setBillTokenFactory(address(factory));

        batchHelper = new DiscountBillBatchHelper(address(bill));

        // Grant OPERATOR_ROLE to batch helper so it can call issue()
        bytes32 operatorRole = bill.OPERATOR_ROLE();
        vm.prank(admin);
        bill.grantRole(operatorRole, address(batchHelper));

        token.mint(depositor, 100_000 ether);
        vm.prank(depositor);
        token.approve(address(bill), type(uint256).max);
    }

    function testBatchIssueCreatesMultipleBills() public {
        DiscountBillBatchHelper.IssueParams[] memory params = new DiscountBillBatchHelper.IssueParams[](3);
        for (uint256 i = 0; i < 3; i++) {
            params[i] = DiscountBillBatchHelper.IssueParams({
                owner: owner1,
                depositor: depositor,
                depositWallet: depositWallet,
                introducingWallet: introducingWallet,
                token: address(token),
                principal: PRINCIPAL,
                annualRateBps: 36_500,
                durationInDays: 30
            });
        }

        uint256[] memory ids = batchHelper.batchIssue(params);
        assertEq(ids.length, 3);

        // Verify each bill exists and is owned correctly
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(bill.ownerOf(ids[i]), owner1);
            IDiscountBill.BillInfo memory info = bill.getBillInfo(ids[i]);
            assertEq(info.principal, PRINCIPAL);
            assertEq(info.token, address(token));
        }

        // Verify sequential IDs
        assertEq(ids[1], ids[0] + 1);
        assertEq(ids[2], ids[1] + 1);
    }

    function testBatchIssueRevertsOnEmpty() public {
        DiscountBillBatchHelper.IssueParams[] memory params = new DiscountBillBatchHelper.IssueParams[](0);
        vm.expectRevert(DiscountBillBatchHelper.EmptyBatch.selector);
        batchHelper.batchIssue(params);
    }

    function testGetBillsBatch() public {
        // Issue a few bills via the batch helper
        DiscountBillBatchHelper.IssueParams[] memory params = new DiscountBillBatchHelper.IssueParams[](2);
        for (uint256 i = 0; i < 2; i++) {
            params[i] = DiscountBillBatchHelper.IssueParams({
                owner: owner1,
                depositor: depositor,
                depositWallet: depositWallet,
                introducingWallet: introducingWallet,
                token: address(token),
                principal: PRINCIPAL * (i + 1),
                annualRateBps: 36_500,
                durationInDays: 30
            });
        }
        uint256[] memory ids = batchHelper.batchIssue(params);

        // Fetch batch
        IDiscountBill.BillInfo[] memory infos = batchHelper.getBillsBatch(ids);
        assertEq(infos.length, 2);
        assertEq(infos[0].principal, PRINCIPAL);
        assertEq(infos[1].principal, PRINCIPAL * 2);
    }

    function testBatchIssueDifferentOwners() public {
        address owner2 = makeAddr("owner2");

        DiscountBillBatchHelper.IssueParams[] memory params = new DiscountBillBatchHelper.IssueParams[](2);
        params[0] = DiscountBillBatchHelper.IssueParams({
            owner: owner1,
            depositor: depositor,
            depositWallet: depositWallet,
            introducingWallet: introducingWallet,
            token: address(token),
            principal: PRINCIPAL,
            annualRateBps: 10_000,
            durationInDays: 90
        });
        params[1] = DiscountBillBatchHelper.IssueParams({
            owner: owner2,
            depositor: depositor,
            depositWallet: depositWallet,
            introducingWallet: introducingWallet,
            token: address(token),
            principal: PRINCIPAL * 2,
            annualRateBps: 5_000,
            durationInDays: 180
        });

        uint256[] memory ids = batchHelper.batchIssue(params);
        assertEq(bill.ownerOf(ids[0]), owner1);
        assertEq(bill.ownerOf(ids[1]), owner2);
    }
}
