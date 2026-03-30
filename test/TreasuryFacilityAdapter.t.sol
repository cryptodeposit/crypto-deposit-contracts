// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TreasuryFacilityAdapter} from "../src/adapters/TreasuryFacilityAdapter.sol";

// ============================================================================
// Mock ERC20
// ============================================================================

contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _decimals = dec_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

// ============================================================================
// Tests
// ============================================================================

contract TreasuryFacilityAdapterTest is Test {
    TreasuryFacilityAdapter public adapter;
    MockToken public usdc;
    MockToken public usdt;

    address public admin = address(this);
    address public custody = makeAddr("custody");
    address public treasury = makeAddr("treasury");
    address public attacker = makeAddr("attacker");

    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        usdt = new MockToken("Tether USD", "USDT", 6);

        adapter = new TreasuryFacilityAdapter(admin, custody);

        // Add supported tokens
        adapter.addSupportedToken(address(usdc));
        adapter.addSupportedToken(address(usdt));

        // Grant TREASURY_ROLE to the treasury mock
        adapter.grantRole(TREASURY_ROLE, treasury);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_constructor_setsAdmin() public view {
        assertTrue(adapter.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_constructor_setsCustody() public view {
        assertEq(adapter.custodyAddress(), custody);
    }

    function test_constructor_grantsAllRolesToAdmin() public view {
        assertTrue(adapter.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(adapter.hasRole(TREASURY_ROLE, admin));
        assertTrue(adapter.hasRole(OPERATOR_ROLE, admin));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert("admin=0");
        new TreasuryFacilityAdapter(address(0), custody);
    }

    function test_constructor_revertsOnZeroCustody() public {
        vm.expectRevert("custody=0");
        new TreasuryFacilityAdapter(admin, address(0));
    }

    // =========================================================================
    // IStrategyAdapter view functions
    // =========================================================================

    function test_name() public view {
        assertEq(adapter.name(), "Treasury Facility");
    }

    function test_isLiquid() public view {
        assertFalse(adapter.isLiquid());
    }

    function test_supportsToken_added() public view {
        assertTrue(adapter.supportsToken(address(usdc)));
        assertTrue(adapter.supportsToken(address(usdt)));
    }

    function test_supportsToken_notAdded() public view {
        assertFalse(adapter.supportsToken(address(0xdead)));
    }

    function test_totalDeployed_initiallyZero() public view {
        assertEq(adapter.totalDeployed(address(usdc)), 0);
    }

    function test_currentValue_equalsTotalDeployed() public {
        // Fund adapter and deploy
        usdc.mint(address(adapter), 1000e6);
        vm.prank(treasury);
        adapter.deploy(address(usdc), 1000e6);

        assertEq(adapter.currentValue(address(usdc)), adapter.totalDeployed(address(usdc)));
    }

    // =========================================================================
    // addSupportedToken
    // =========================================================================

    function test_addSupportedToken_emitsEvent() public {
        MockToken newToken = new MockToken("DAI", "DAI", 18);
        vm.expectEmit(true, false, false, false);
        emit TreasuryFacilityAdapter.TokenAdded(address(newToken));
        adapter.addSupportedToken(address(newToken));
    }

    function test_addSupportedToken_revertsOnZeroAddress() public {
        vm.expectRevert("token=0");
        adapter.addSupportedToken(address(0));
    }

    function test_addSupportedToken_revertsForNonAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        adapter.addSupportedToken(address(usdc));
    }

    // =========================================================================
    // setCustodyAddress
    // =========================================================================

    function test_setCustodyAddress_updates() public {
        address newCustody = makeAddr("newCustody");
        adapter.setCustodyAddress(newCustody);
        assertEq(adapter.custodyAddress(), newCustody);
    }

    function test_setCustodyAddress_emitsEvent() public {
        address newCustody = makeAddr("newCustody");
        vm.expectEmit(true, true, false, false);
        emit TreasuryFacilityAdapter.CustodyAddressUpdated(custody, newCustody);
        adapter.setCustodyAddress(newCustody);
    }

    function test_setCustodyAddress_revertsOnZero() public {
        vm.expectRevert("custody=0");
        adapter.setCustodyAddress(address(0));
    }

    function test_setCustodyAddress_revertsForNonAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        adapter.setCustodyAddress(makeAddr("newCustody"));
    }

    // =========================================================================
    // deploy
    // =========================================================================

    function test_deploy_transfersToCustody() public {
        usdc.mint(address(adapter), 1000e6);

        vm.prank(treasury);
        adapter.deploy(address(usdc), 1000e6);

        assertEq(usdc.balanceOf(custody), 1000e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }

    function test_deploy_updatesDeployedTracking() public {
        usdc.mint(address(adapter), 1000e6);

        vm.prank(treasury);
        adapter.deploy(address(usdc), 1000e6);

        assertEq(adapter.totalDeployed(address(usdc)), 1000e6);
    }

    function test_deploy_accumulatesAcrossMultipleCalls() public {
        usdc.mint(address(adapter), 2000e6);

        vm.startPrank(treasury);
        adapter.deploy(address(usdc), 500e6);
        adapter.deploy(address(usdc), 700e6);
        vm.stopPrank();

        assertEq(adapter.totalDeployed(address(usdc)), 1200e6);
        assertEq(usdc.balanceOf(custody), 1200e6);
    }

    function test_deploy_tracksMultipleTokensSeparately() public {
        usdc.mint(address(adapter), 1000e6);
        usdt.mint(address(adapter), 500e6);

        vm.startPrank(treasury);
        adapter.deploy(address(usdc), 1000e6);
        adapter.deploy(address(usdt), 500e6);
        vm.stopPrank();

        assertEq(adapter.totalDeployed(address(usdc)), 1000e6);
        assertEq(adapter.totalDeployed(address(usdt)), 500e6);
    }

    function test_deploy_revertsForUnsupportedToken() public {
        MockToken unsupported = new MockToken("X", "X", 18);
        unsupported.mint(address(adapter), 100e18);

        vm.prank(treasury);
        vm.expectRevert("token not supported");
        adapter.deploy(address(unsupported), 100e18);
    }

    function test_deploy_revertsForZeroAmount() public {
        vm.prank(treasury);
        vm.expectRevert("amount=0");
        adapter.deploy(address(usdc), 0);
    }

    function test_deploy_revertsWithoutTreasuryRole() public {
        usdc.mint(address(adapter), 1000e6);

        vm.prank(attacker);
        vm.expectRevert();
        adapter.deploy(address(usdc), 1000e6);
    }

    // =========================================================================
    // withdraw
    // =========================================================================

    function test_withdraw_pullsFromCustody() public {
        // Setup: deploy tokens to custody
        usdc.mint(address(adapter), 1000e6);
        vm.prank(treasury);
        adapter.deploy(address(usdc), 1000e6);

        // Custody must approve adapter for withdrawal
        vm.prank(custody);
        usdc.approve(address(adapter), 1000e6);

        // Withdraw back to treasury (msg.sender)
        vm.prank(treasury);
        uint256 withdrawn = adapter.withdraw(address(usdc), 500e6);

        assertEq(withdrawn, 500e6);
        assertEq(usdc.balanceOf(treasury), 500e6);
        assertEq(usdc.balanceOf(custody), 500e6);
    }

    function test_withdraw_updatesDeployedTracking() public {
        usdc.mint(address(adapter), 1000e6);
        vm.prank(treasury);
        adapter.deploy(address(usdc), 1000e6);

        vm.prank(custody);
        usdc.approve(address(adapter), 1000e6);

        vm.prank(treasury);
        adapter.withdraw(address(usdc), 400e6);

        assertEq(adapter.totalDeployed(address(usdc)), 600e6);
    }

    function test_withdraw_fullAmount() public {
        usdc.mint(address(adapter), 1000e6);
        vm.prank(treasury);
        adapter.deploy(address(usdc), 1000e6);

        vm.prank(custody);
        usdc.approve(address(adapter), 1000e6);

        vm.prank(treasury);
        adapter.withdraw(address(usdc), 1000e6);

        assertEq(adapter.totalDeployed(address(usdc)), 0);
        assertEq(usdc.balanceOf(treasury), 1000e6);
        assertEq(usdc.balanceOf(custody), 0);
    }

    function test_withdraw_clampsDeployedToZero() public {
        // Edge case: if withdraw amount exceeds tracked deployed (shouldn't
        // happen normally, but deployed is clamped to 0 not underflow)
        usdc.mint(address(adapter), 1000e6);
        vm.prank(treasury);
        adapter.deploy(address(usdc), 500e6);

        // Custody has extra tokens and approves
        usdc.mint(custody, 500e6);
        vm.prank(custody);
        usdc.approve(address(adapter), 1000e6);

        // Withdraw more than deployed — should clamp to 0
        vm.prank(treasury);
        adapter.withdraw(address(usdc), 700e6);

        assertEq(adapter.totalDeployed(address(usdc)), 0);
    }

    function test_withdraw_revertsForUnsupportedToken() public {
        MockToken unsupported = new MockToken("X", "X", 18);

        vm.prank(treasury);
        vm.expectRevert("token not supported");
        adapter.withdraw(address(unsupported), 100);
    }

    function test_withdraw_revertsForZeroAmount() public {
        vm.prank(treasury);
        vm.expectRevert("amount=0");
        adapter.withdraw(address(usdc), 0);
    }

    function test_withdraw_revertsWithoutTreasuryRole() public {
        vm.prank(attacker);
        vm.expectRevert();
        adapter.withdraw(address(usdc), 100e6);
    }

    function test_withdraw_revertsIfCustodyNotApproved() public {
        usdc.mint(address(adapter), 1000e6);
        vm.prank(treasury);
        adapter.deploy(address(usdc), 1000e6);

        // No approval from custody — should revert
        vm.prank(treasury);
        vm.expectRevert();
        adapter.withdraw(address(usdc), 500e6);
    }

    // =========================================================================
    // Access control edge cases
    // =========================================================================

    function test_operatorRole_cannotDeploy() public {
        // OPERATOR_ROLE is defined but deploy requires TREASURY_ROLE
        address operator = makeAddr("operator");
        adapter.grantRole(OPERATOR_ROLE, operator);

        usdc.mint(address(adapter), 100e6);

        vm.prank(operator);
        vm.expectRevert();
        adapter.deploy(address(usdc), 100e6);
    }

    function test_adminCanRevokeRoles() public {
        adapter.revokeRole(TREASURY_ROLE, treasury);
        assertFalse(adapter.hasRole(TREASURY_ROLE, treasury));

        usdc.mint(address(adapter), 100e6);
        vm.prank(treasury);
        vm.expectRevert();
        adapter.deploy(address(usdc), 100e6);
    }

    // =========================================================================
    // Full lifecycle: deploy → withdraw
    // =========================================================================

    function test_fullLifecycle() public {
        uint256 amount = 50_000e6; // 50k USDC

        // 1. Fund adapter (Treasury would call transferFrom in real flow)
        usdc.mint(address(adapter), amount);

        // 2. Deploy to custody
        vm.prank(treasury);
        adapter.deploy(address(usdc), amount);

        assertEq(usdc.balanceOf(custody), amount);
        assertEq(adapter.totalDeployed(address(usdc)), amount);
        assertEq(adapter.currentValue(address(usdc)), amount);

        // 3. Time passes... exchange earns yield off-chain

        // 4. Custody returns tokens (approve + has balance)
        vm.prank(custody);
        usdc.approve(address(adapter), amount);

        // 5. Withdraw back
        vm.prank(treasury);
        uint256 withdrawn = adapter.withdraw(address(usdc), amount);

        assertEq(withdrawn, amount);
        assertEq(usdc.balanceOf(treasury), amount);
        assertEq(adapter.totalDeployed(address(usdc)), 0);
        assertEq(adapter.currentValue(address(usdc)), 0);
    }

    function test_fullLifecycle_partialWithdrawals() public {
        usdc.mint(address(adapter), 10_000e6);

        vm.prank(treasury);
        adapter.deploy(address(usdc), 10_000e6);

        vm.prank(custody);
        usdc.approve(address(adapter), 10_000e6);

        // Withdraw in chunks
        vm.startPrank(treasury);
        adapter.withdraw(address(usdc), 3_000e6);
        assertEq(adapter.totalDeployed(address(usdc)), 7_000e6);

        adapter.withdraw(address(usdc), 5_000e6);
        assertEq(adapter.totalDeployed(address(usdc)), 2_000e6);

        adapter.withdraw(address(usdc), 2_000e6);
        assertEq(adapter.totalDeployed(address(usdc)), 0);
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasury), 10_000e6);
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_deploy_anyValidAmount(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);

        usdc.mint(address(adapter), amount);
        vm.prank(treasury);
        adapter.deploy(address(usdc), amount);

        assertEq(adapter.totalDeployed(address(usdc)), amount);
        assertEq(usdc.balanceOf(custody), amount);
    }

    function testFuzz_deployAndWithdraw_roundTrip(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint128).max);

        usdc.mint(address(adapter), amount);
        vm.prank(treasury);
        adapter.deploy(address(usdc), amount);

        vm.prank(custody);
        usdc.approve(address(adapter), amount);

        vm.prank(treasury);
        uint256 withdrawn = adapter.withdraw(address(usdc), amount);

        assertEq(withdrawn, amount);
        assertEq(adapter.totalDeployed(address(usdc)), 0);
        assertEq(usdc.balanceOf(treasury), amount);
    }
}
