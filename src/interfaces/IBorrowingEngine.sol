// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IBorrowingEngine
 * @notice Interface for the loan management contract
 * @dev Manages loan positions with interest accrual and health factor calculations.
 *      Integrates with CollateralVault for margin checks and TravelRule for compliance.
 */
interface IBorrowingEngine {
    struct Loan {
        address borrower;
        address token;              // Borrowed asset
        uint256 principal;          // Original borrow amount
        uint256 accruedInterest;    // Accumulated interest
        uint256 lastAccrualTime;    // Last interest calculation timestamp
        uint256 ratePerSecond;      // Interest rate per second (scaled 1e27 ray)
        bool active;
    }

    event LoanCreated(uint256 indexed loanId, address indexed borrower, address indexed token, uint256 amount, uint256 ratePerSecond);
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, uint256 principalRepaid, uint256 interestRepaid);
    event InterestAccrued(uint256 indexed loanId, uint256 interestAdded, uint256 totalAccrued);
    event RateUpdated(address indexed token, uint256 oldRate, uint256 newRate);
    event LiquidityAdded(address indexed token, uint256 amount);
    event LiquidityRemoved(address indexed token, uint256 amount);

    function borrow(address token, uint256 amount) external returns (uint256 loanId);
    function repay(uint256 loanId, uint256 amount) external;
    function accrueInterest(uint256 loanId) external;

    function getHealthFactor(address client) external view returns (uint256 healthFactorBps);
    function getTotalBorrowValue(address client) external view returns (uint256 totalValueUsd);
    function getLoan(uint256 loanId) external view returns (Loan memory);
    function getUserLoans(address client) external view returns (uint256[] memory loanIds);
    function getAvailableLiquidity(address token) external view returns (uint256);
    function getTotalBorrowed(address token) external view returns (uint256);
    function getBorrowRate(address token) external view returns (uint256 ratePerSecond);
}
