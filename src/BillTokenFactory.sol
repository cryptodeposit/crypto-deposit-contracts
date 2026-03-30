// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDiscountBillERC5095} from "./interfaces/IDiscountBillERC5095.sol";
import {IERC5095} from "./interfaces/IERC5095.sol";

/**
 * @title DiscountBillERC5095Token
 * @notice ERC-5095 fungible token representing a share of a discount bill
 * @dev Deployed per-bill by BillTokenFactory. References the parent bill
 *      via IDiscountBillERC5095 interface to avoid circular imports.
 */
contract DiscountBillERC5095Token is ERC20, IERC5095 {
    IDiscountBillERC5095 public immutable bill;
    address public immutable underlyingAsset;
    uint256 public immutable maturityTimestamp;
    uint256 public immutable billId;
    uint8 private immutable _decimals;

    constructor(
        address bill_,
        uint256 billId_,
        address underlying_,
        uint256 maturity_,
        uint8 decimals_,
        address initialHolder,
        uint256 amount
    ) ERC20("DiscountBill5095", "DBILL5095") {
        bill = IDiscountBillERC5095(bill_);
        billId = billId_;
        underlyingAsset = underlying_;
        maturityTimestamp = maturity_;
        _decimals = decimals_;
        _mint(initialHolder, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function underlying() external view override returns (address) {
        return underlyingAsset;
    }

    function maturity() external view override returns (uint256) {
        return maturityTimestamp;
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        uint256 remaining = bill.redeemableValue(billId);
        uint256 balance = balanceOf(owner);
        return remaining < balance ? remaining : balance;
    }

    function previewRedeem(uint256 amount) external view override returns (uint256) {
        return bill.previewRedeem(billId, amount);
    }

    function redeem(uint256 amount, address receiver, address owner) external override returns (uint256) {
        require(bill.canRedeem(billId, amount), "Redeem unavailable");
        if (msg.sender != owner) {
            uint256 currentAllowance = allowance(owner, msg.sender);
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, msg.sender, currentAllowance - amount);
            }
        }

        _burn(owner, amount);
        uint256 payout = bill.redeemViaToken(billId, amount, receiver, msg.sender);
        require(payout > 0, "Redemption failed");
        return payout;
    }

    function burnFrom(address account, uint256 amount) external {
        require(msg.sender == address(bill), "Only parent contract");
        _burn(account, amount);
    }
}

/**
 * @title BillTokenFactory
 * @notice Deploys DiscountBillERC5095Token instances
 * @dev Separating token deployment from the bill contract removes ~4.5KB
 *      of embedded creation bytecode from the main contract.
 */
contract BillTokenFactory {
    event BillTokenDeployed(uint256 indexed billId, address indexed token, address indexed billContract);

    function deployBillToken(
        address billContract,
        uint256 billId,
        address underlyingToken,
        uint256 maturityTimestamp,
        uint8 tokenDecimals,
        address initialHolder,
        uint256 amount
    ) external returns (address tokenAddress) {
        tokenAddress = address(
            new DiscountBillERC5095Token(
                billContract,
                billId,
                underlyingToken,
                maturityTimestamp,
                tokenDecimals,
                initialHolder,
                amount
            )
        );
        emit BillTokenDeployed(billId, tokenAddress, billContract);
    }
}
