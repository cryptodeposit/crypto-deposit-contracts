// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title BillMathLib
 * @notice External library for discount bill financial math
 * @dev External library functions are deployed as a separate contract and called
 *      via DELEGATECALL, reducing the calling contract's bytecode size.
 *      Shared by DiscountBillUpgradeable and DiscountBillERC5095Upgradeable.
 *
 *      Internal helpers (_pow) are inlined into the external functions that use them.
 */
library BillMathLib {
    /// @dev Internal binary exponentiation: (1 + dailyRate)^days
    function _pow(uint256 base, uint256 ratePerDayScaled, uint256 daysToMaturity)
        private
        pure
        returns (uint256)
    {
        uint256 result = base;
        uint256 multiplier = base + ratePerDayScaled;
        while (daysToMaturity > 0) {
            if (daysToMaturity % 2 == 1) {
                result = Math.mulDiv(result, multiplier, base, Math.Rounding.Floor);
            }
            multiplier = Math.mulDiv(multiplier, multiplier, base, Math.Rounding.Floor);
            unchecked { daysToMaturity >>= 1; }
        }
        return result;
    }

    /// @notice Binary exponentiation for compound growth: (1 + dailyRate)^days
    /// @param base Scale factor (1e18)
    /// @param ratePerDayScaled Daily rate scaled by 1e18
    /// @param daysToMaturity Number of compounding days
    function pow(uint256 base, uint256 ratePerDayScaled, uint256 daysToMaturity)
        external
        pure
        returns (uint256)
    {
        return _pow(base, ratePerDayScaled, daysToMaturity);
    }

    /// @notice Apply compound growth to an amount
    function applyGrowth(uint256 amount, uint256 ratePerDayScaled, uint256 daysToMaturity)
        external
        pure
        returns (uint256)
    {
        uint256 growth = _pow(1e18, ratePerDayScaled, daysToMaturity);
        return Math.mulDiv(amount, growth, 1e18, Math.Rounding.Floor);
    }

    /// @notice Calculate bill terms: final amount and commission
    /// @param principal Deposit principal
    /// @param annualRateBps Annual rate in basis points
    /// @param durationInDays Term length in days
    /// @param commissionBps Commission rate in basis points
    function calculateTerms(
        uint256 principal,
        uint256 annualRateBps,
        uint256 durationInDays,
        uint256 commissionBps
    )
        external
        pure
        returns (uint256 finalAmount, uint256 commission)
    {
        uint256 ratePerDayScaled = (annualRateBps * 1e18) / (365 * 10_000);
        uint256 growthFactor = _pow(1e18, ratePerDayScaled, durationInDays);
        finalAmount = Math.mulDiv(principal, growthFactor, 1e18, Math.Rounding.Floor);
        uint256 interestAmount = finalAmount > principal ? finalAmount - principal : 0;
        commission = (interestAmount * commissionBps) / 10_000;
    }

    /// @notice Calculate early redemption payout components
    /// @param principal Bill principal
    /// @param redemptionValue Bill full redemption value
    /// @param issuance Bill issuance timestamp
    /// @param maturityTs Bill maturity timestamp
    /// @param currentTs Current block timestamp
    /// @param isPartial Whether this is a partial redemption
    /// @param redeemAmount Amount to redeem
    /// @param breakFeeBps Break fee in basis points
    function calculateEarlyRedemption(
        uint256 principal,
        uint256 redemptionValue,
        uint256 issuance,
        uint256 maturityTs,
        uint256 currentTs,
        bool isPartial,
        uint256 redeemAmount,
        uint256 breakFeeBps
    )
        external
        pure
        returns (uint256 breakFee, uint256 accruedInterest, uint256 payoutAmount)
    {
        uint256 totalTerm = maturityTs - issuance;
        uint256 elapsed = currentTs > issuance ? currentTs - issuance : 0;
        uint256 remaining = totalTerm > elapsed ? totalTerm - elapsed : 0;

        // Accrued interest (pro-rata)
        uint256 totalInterest = redemptionValue - principal;
        accruedInterest = totalTerm > 0
            ? Math.mulDiv(totalInterest, elapsed, totalTerm)
            : 0;
        if (isPartial && redemptionValue > 0) {
            accruedInterest = Math.mulDiv(accruedInterest, redeemAmount, redemptionValue);
        }

        // Pro-rata break fee
        uint256 principalPortion = isPartial && redemptionValue > 0
            ? Math.mulDiv(principal, redeemAmount, redemptionValue)
            : principal;

        breakFee = totalTerm > 0
            ? Math.mulDiv(
                Math.mulDiv(principalPortion, breakFeeBps, 10_000),
                remaining,
                totalTerm
            )
            : 0;

        // Net payout
        payoutAmount = principalPortion + accruedInterest;
        payoutAmount = payoutAmount > breakFee ? payoutAmount - breakFee : 0;
    }
}
