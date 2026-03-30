// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStrategyAdapter} from "../interfaces/IStrategyAdapter.sol";

/**
 * @title TreasuryFacilityAdapter
 * @notice Strategy adapter for off-chain treasury facility deployment
 * @dev Transfers tokens to a designated custody address for off-chain yield.
 *      NOT liquid — withdrawals require the custody address to have pre-funded tokens.
 *      Used for longer-term fixed-rate facilities that match deposit maturities.
 */
contract TreasuryFacilityAdapter is IStrategyAdapter, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Off-chain custody address that receives deployed tokens
    address public custodyAddress;

    /// @notice Total deployed per token
    mapping(address => uint256) public deployed;
    mapping(address => bool) public supportedTokens;

    event TokenAdded(address indexed token);
    event CustodyAddressUpdated(address indexed oldCustody, address indexed newCustody);

    constructor(address admin_, address custody_) {
        require(admin_ != address(0), "admin=0");
        require(custody_ != address(0), "custody=0");

        custodyAddress = custody_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(TREASURY_ROLE, admin_);
        _grantRole(OPERATOR_ROLE, admin_);
    }

    function addSupportedToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "token=0");
        supportedTokens[token] = true;

        emit TokenAdded(token);
    }

    function setCustodyAddress(address custody_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(custody_ != address(0), "custody=0");
        address oldCustody = custodyAddress;
        custodyAddress = custody_;

        emit CustodyAddressUpdated(oldCustody, custody_);
    }

    // ============================================================================
    // IStrategyAdapter Implementation
    // ============================================================================

    function deploy(address token, uint256 amount) external override onlyRole(TREASURY_ROLE) nonReentrant {
        require(supportedTokens[token], "token not supported");
        require(amount > 0, "amount=0");

        // Transfer to off-chain custody
        IERC20(token).safeTransfer(custodyAddress, amount);
        deployed[token] += amount;
    }

    function withdraw(address token, uint256 amount) external override onlyRole(TREASURY_ROLE) nonReentrant returns (uint256 withdrawn) {
        require(supportedTokens[token], "token not supported");
        require(amount > 0, "amount=0");

        // Pull pre-funded tokens from custody address
        // Custody must have approved this contract
        uint256 balBefore = IERC20(token).balanceOf(msg.sender);
        // Security: custodyAddress is a trusted state variable, only settable by admin
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(token).safeTransferFrom(custodyAddress, msg.sender, amount);
        withdrawn = IERC20(token).balanceOf(msg.sender) - balBefore;

        if (deployed[token] >= amount) {
            deployed[token] -= amount;
        } else {
            deployed[token] = 0;
        }
    }

    function totalDeployed(address token) external view override returns (uint256) {
        return deployed[token];
    }

    function currentValue(address token) external view override returns (uint256) {
        // Off-chain facility — nominal value equals deployed (no on-chain yield tracking)
        return deployed[token];
    }

    function supportsToken(address token) external view override returns (bool) {
        return supportedTokens[token];
    }

    function isLiquid() external pure override returns (bool) {
        return false; // Off-chain — not same-block withdrawable
    }

    function name() external pure override returns (string memory) {
        return "Treasury Facility";
    }
}
