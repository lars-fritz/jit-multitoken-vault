// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Price and volatility adapter used by the prototype vault.
/// @dev A production adapter may read deep Uniswap v3 TWAP observations.
interface IVaultOracle {
    /// @return priceX18 Numeraire value of one 1e18-scaled token unit.
    /// @return updatedAt Timestamp of the underlying observation.
    function priceX18(address asset) external view returns (uint256 priceX18, uint256 updatedAt);

    /// @return volatilityBps Annualized relative volatility in basis points.
    /// @return updatedAt Timestamp of the underlying volatility observation.
    function relativeVolatilityBps(address asset0, address asset1)
        external
        view
        returns (uint256 volatilityBps, uint256 updatedAt);
}
