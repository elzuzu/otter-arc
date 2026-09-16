// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ArcDecimals
 * @notice Conversions between Arc's two representations of one and the same USDC balance.
 *
 * @dev Arc Mainnet (chain ID 5042) exposes USDC twice, and the two views share a single
 *      underlying balance:
 *
 *        - The **native gas asset**, denominated in **18 decimals**. This is what `msg.value`,
 *          `address(x).balance` and `eth_getBalance` speak. It is the unit every payable
 *          function in this protocol is denominated in.
 *
 *        - The **ERC-20 predeploy** at `0x3600000000000000000000000000000000000000`,
 *          denominated in **6 decimals** — the familiar USDC precision.
 *
 *      The ERC-20 view is the native balance divided by `1e12` and truncated toward zero.
 *      Verified against Arc Mainnet: a validator holding `16223.444459367` USDC of native
 *      balance reports `16223.444459` from `balanceOf`, i.e. `floor(native / 1e12) == balanceOf`.
 *
 *      Getting this wrong is the single most likely integration bug on Arc: assuming 6 decimals
 *      for the native asset overstates every balance by a factor of 10^12.
 */
library ArcDecimals {
    /// @notice Decimals of Arc's native gas asset, as seen by `msg.value` and `balance`.
    uint8 internal constant NATIVE_DECIMALS = 18;

    /// @notice Decimals of the USDC ERC-20 predeploy.
    uint8 internal constant ERC20_DECIMALS = 6;

    /// @notice Ratio between the two representations: 10 ** (18 - 6).
    uint256 internal constant SCALE = 1e12;

    /// @notice Canonical address of the USDC ERC-20 predeploy on Arc.
    address internal constant USDC_ERC20 = 0x3600000000000000000000000000000000000000;

    /**
     * @notice Convert a native-denominated amount (18 decimals) to ERC-20 USDC units (6 decimals).
     * @dev Truncates toward zero, discarding up to `SCALE - 1` native units — strictly less than
     *      one millionth of a USDC. This mirrors exactly what the predeploy reports.
     */
    function toErc20Units(uint256 nativeAmount) internal pure returns (uint256) {
        return nativeAmount / SCALE;
    }

    /**
     * @notice Convert an ERC-20 USDC amount (6 decimals) to native units (18 decimals).
     * @dev Exact and lossless. Reverts on overflow under Solidity >=0.8 checked arithmetic.
     */
    function toNativeUnits(uint256 erc20Amount) internal pure returns (uint256) {
        return erc20Amount * SCALE;
    }

    /**
     * @notice Native units that `toErc20Units` would discard for `nativeAmount`.
     * @dev Always in `[0, SCALE)`. Exposed so callers can surface the rounding rather than
     *      silently absorb it.
     */
    function truncationRemainder(uint256 nativeAmount) internal pure returns (uint256) {
        return nativeAmount % SCALE;
    }
}

/// @notice Minimal view surface of the Arc USDC ERC-20 predeploy.
interface IArcUsdc {
    function balanceOf(address account) external view returns (uint256);

    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);
}
