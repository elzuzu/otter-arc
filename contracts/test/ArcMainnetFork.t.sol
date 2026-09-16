// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ArcAgentGateway} from "../src/ArcAgentGateway.sol";
import {ArcDecimals, IArcUsdc} from "../src/ArcDecimals.sol";

/**
 * @title ArcMainnetForkTest
 * @notice Turns this project's central claim about Arc into an executable assertion.
 *
 * @dev The claim: on Arc Mainnet the native gas asset carries 18 decimals while the USDC ERC-20
 *      predeploy carries 6, and both read the same underlying balance, related by 1e12. Rather
 *      than asserting that in prose, these tests fork Arc Mainnet and check it against the live
 *      chain. Run with:
 *
 *        forge test --match-path 'test/ArcMainnetFork.t.sol' --fork-url https://rpc.mainnet.arc.io
 *
 *      The fork endpoint is configured in foundry.toml, so `forge test` alone runs them. These
 *      tests require network access by design: a claim about a live chain that can silently skip
 *      itself is not a proof.
 */
contract ArcMainnetForkTest is Test {
    uint256 internal constant ARC_CHAIN_ID = 5042;
    address internal constant USDC_ERC20 = 0x3600000000000000000000000000000000000000;

    /// @dev An Arc Mainnet validator address, used as a live sample with a non-trivial balance.
    address internal constant SAMPLE = 0x5ACCC00D7e4dB975CCbfC2801bC9447f37198797;

    /**
     * @dev Forks Arc Mainnet for every test in this suite. The endpoint is declared as `arc` in
     *      foundry.toml, so a plain `forge test` exercises these assertions against the live
     *      chain — there is deliberately no self-skip path that could report a green suite
     *      without the proof having actually run.
     */
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("arc"));
        assertEq(block.chainid, ARC_CHAIN_ID, "fork must be Arc Mainnet");
    }

    /// @notice The USDC ERC-20 predeploy exists and reports 6 decimals.
    function testFork_PredeployReportsSixDecimals() public view {
        assertGt(USDC_ERC20.code.length, 0, "predeploy must be a contract");
        assertEq(IArcUsdc(USDC_ERC20).decimals(), 6, "ERC-20 USDC on Arc is 6 decimals");
    }

    /// @notice Native balance and ERC-20 balance are the same money, scaled by 1e12.
    function testFork_NativeAndErc20AreTheSameBalance() public view {
        uint256 native = SAMPLE.balance;
        uint256 erc20 = IArcUsdc(USDC_ERC20).balanceOf(SAMPLE);

        assertGt(native, 0, "sample account must hold a balance on the forked block");
        assertEq(native / 1e12, erc20, "floor(native / 1e12) == balanceOf");

        console.log("native (18 dec):", native);
        console.log("erc20  ( 6 dec):", erc20);
    }

    /// @notice The native asset is NOT 6 decimals. Guards against the bug this project shipped.
    function testFork_NativeIsNotSixDecimals() public {
        uint256 native = SAMPLE.balance;
        uint256 erc20 = IArcUsdc(USDC_ERC20).balanceOf(SAMPLE);

        // If the native asset were 6 decimals, it and the 6-decimal ERC-20 view would report the
        // same number. They do not.
        assertTrue(native != erc20, "native and ERC-20 readings cannot be the same number");

        // Exact reconstruction: the native balance is the ERC-20 value scaled up by 1e12 plus the
        // sub-micro-USDC remainder. This identity holds only because native carries 18 decimals.
        assertEq(erc20 * 1e12 + (native % 1e12), native, "native == erc20 * 1e12 + remainder");

        // And the misreading is not merely wrong, it is impossible: interpreting the raw native
        // balance as a 6-decimal USDC amount credits this single account with more USDC than
        // exists on the whole chain.
        //
        // `totalSupply()` cannot be read through the forked EVM: the predeploy at 0x3600 is a
        // proxy whose implementation routes totalSupply to an Arc precompile at
        // 0x1800000000000000000000000000000000000000, which holds no bytecode and which REVM
        // therefore rejects with OpcodeNotFound. We query the live node directly instead.
        uint256 misread = native; // raw units read as if they were 6-decimal USDC
        uint256 supply = _liveTotalSupply();
        assertGt(supply, 0, "live supply must be readable");
        assertGt(misread, supply, "6-decimal misreading exceeds Arc's entire USDC supply");

        console.log("total USDC supply on Arc (6 dec):", supply);
        console.log("this account misread as 6 dec   :", misread);
    }

    /**
     * @notice Read `totalSupply()` from the live Arc node, bypassing the forked EVM.
     * @dev Necessary because the call terminates in an Arc precompile (0x1800...0000) that has no
     *      bytecode and cannot be executed by a local EVM. `vm.rpc` performs a real `eth_call`.
     */
    function _liveTotalSupply() internal returns (uint256) {
        bytes memory raw = vm.rpc(
            "eth_call",
            '[{"to":"0x3600000000000000000000000000000000000000","data":"0x18160ddd"},"latest"]'
        );
        return abi.decode(raw, (uint256));
    }

    /// @notice The deployed contract's own view agrees with the live chain.
    function testFork_GatewayViewMatchesChain() public {
        ArcAgentGateway gateway = new ArcAgentGateway();
        (uint256 native, uint256 erc20, uint256 remainder) = gateway.nativeBalanceAsErc20(SAMPLE);

        assertEq(native, SAMPLE.balance);
        assertEq(erc20, IArcUsdc(USDC_ERC20).balanceOf(SAMPLE));
        assertEq(native / 1e12, erc20);
        assertEq(remainder, native % 1e12);
        assertLt(remainder, 1e12);
    }
}
