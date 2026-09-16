// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ArcAgentGateway} from "../src/ArcAgentGateway.sol";
import {ArcDecimals, IArcUsdc} from "../src/ArcDecimals.sol";

contract ArcAgentGatewayTest is Test {
    ArcAgentGateway public gateway;
    address public provider = makeAddr("provider");
    address public agentPayer = makeAddr("agentPayer");
    address public workerAgent = makeAddr("workerAgent");

    /// @dev One USDC in Arc native units: 18 decimals, NOT 6.
    uint256 internal constant ONE_USDC = 1e18;

    function setUp() public {
        gateway = new ArcAgentGateway();
        // Fund test addresses with native USDC. Arc's native asset has 18 decimals, so
        // 100 USDC == 100e18 == 100 ether in Solidity's unit syntax.
        vm.deal(agentPayer, 100 * ONE_USDC);
        vm.deal(provider, 10 * ONE_USDC);
    }

    // ==========================================
    // Denomination
    // ==========================================

    function test_ContractIsDenominatedInNativeUnits() public view {
        assertEq(gateway.NATIVE_DECIMALS(), 18, "Arc native gas asset is 18 decimals");
        assertEq(gateway.ERC20_DECIMALS(), 6, "Arc USDC ERC-20 predeploy is 6 decimals");
        assertEq(gateway.SCALE(), 1e12, "scale between the two representations");
        assertEq(gateway.ONE_USDC(), 1e18, "one USDC in native units");
        assertEq(gateway.USDC_ERC20(), 0x3600000000000000000000000000000000000000);
    }

    function test_DecimalConversionRoundTrip() public view {
        // Exact round trip: an amount that is a whole number of ERC-20 units survives intact.
        uint256 erc20Amount = 16_223_444_459; // 16223.444459 USDC at 6 decimals
        uint256 native = gateway.toNativeUnits(erc20Amount);
        assertEq(native, erc20Amount * 1e12, "upscaling is a pure multiplication");
        assertEq(gateway.toErc20Units(native), erc20Amount, "round trip is lossless");
    }

    function test_DecimalConversionTruncatesBelowOneMicroUsdc() public view {
        // The real validator balance measured on Arc Mainnet: 16223.444459367 USDC.
        uint256 native = 16_223_444_459_367_000_000_000;
        uint256 erc20 = gateway.toErc20Units(native);

        assertEq(erc20, 16_223_444_459, "matches what the predeploy reports");
        // Truncation loss is strictly bounded by one ERC-20 unit worth of native value.
        uint256 remainder = native - gateway.toNativeUnits(erc20);
        assertLt(remainder, 1e12, "loss is under one millionth of a USDC");
        assertEq(remainder, 367_000_000_000);
    }

    function testFuzz_ConversionNeverOverstates(uint96 nativeAmount) public view {
        uint256 erc20 = gateway.toErc20Units(nativeAmount);
        // Downscaling must never invent value, and never lose a whole ERC-20 unit.
        assertLe(gateway.toNativeUnits(erc20), nativeAmount);
        assertLt(nativeAmount - gateway.toNativeUnits(erc20), 1e12);
    }

    // ==========================================
    // Pay-per-call
    // ==========================================

    function test_RegisterAndPayService() public {
        // 1. Provider registers a service: 0.05 USDC fee == 5e16 native units
        vm.startPrank(provider);
        uint256 fee = 5e16; // 0.05 USDC
        uint256 serviceId = gateway.registerService("Arc-DeepSeek-Agent", "https://api.arcagent.internal/v1", fee);
        assertEq(serviceId, 1);
        vm.stopPrank();

        // 2. Agent calls service and pays exact fee
        vm.startPrank(agentPayer);
        bytes32 queryHash = keccak256("prompt:analyze_liquidity_dex");
        gateway.payForService{value: fee}(serviceId, queryHash);
        vm.stopPrank();

        // Check counters, revenue & provider balance
        (,,,,, , uint256 totalCalls, uint256 totalRevenue) = gateway.services(serviceId);
        assertEq(totalCalls, 1, "call counter incremented");
        assertEq(totalRevenue, fee, "revenue accrued");
        assertEq(gateway.claimableBalances(provider), fee);

        // 3. Provider withdraws earnings
        uint256 balBefore = provider.balance;
        vm.prank(provider);
        gateway.withdraw();
        assertEq(provider.balance, balBefore + fee);
        assertEq(gateway.claimableBalances(provider), 0);
    }

    function test_PayServiceWithExcessRefund() public {
        vm.prank(provider);
        uint256 serviceId = gateway.registerService("Arc-Fast-OCR", "https://api.ocr.arc/v1", 2e16); // 0.02 USDC

        uint256 payerBalBefore = agentPayer.balance;
        vm.prank(agentPayer);
        // Pay 0.1 USDC when fee is 0.02 USDC (excess 0.08 USDC should be refunded)
        gateway.payForService{value: 1e17}(serviceId, keccak256("image_task"));

        assertEq(agentPayer.balance, payerBalBefore - 2e16, "only the fee leaves the payer");
        assertEq(gateway.claimableBalances(provider), 2e16);
    }

    function test_PayServiceRevertsBelowFee() public {
        vm.prank(provider);
        uint256 serviceId = gateway.registerService("Arc-Fast-OCR", "https://api.ocr.arc/v1", 2e16);

        vm.prank(agentPayer);
        vm.expectRevert("Insufficient native USDC sent");
        gateway.payForService{value: 2e16 - 1}(serviceId, keccak256("underpaid"));
    }

    // ==========================================
    // Escrow
    // ==========================================

    function test_EscrowWorkflow() public {
        uint256 escrowAmount = 10 * ONE_USDC; // 10 USDC
        bytes32 taskHash = keccak256("autonomous_trading_scan");
        uint256 deadline = block.timestamp + 1 hours;

        // Payer creates escrow
        vm.prank(agentPayer);
        uint256 escrowId = gateway.createEscrow{value: escrowAmount}(payable(workerAgent), taskHash, deadline);
        assertEq(escrowId, 1);

        // Worker completes escrow
        vm.prank(workerAgent);
        gateway.completeEscrow(escrowId, "result: arbitrage opportunity found at block 4029");

        // Worker withdraws
        vm.prank(workerAgent);
        gateway.withdraw();
        assertEq(workerAgent.balance, escrowAmount);
    }

    function test_EscrowRefundAfterDeadline() public {
        uint256 escrowAmount = 5 * ONE_USDC; // 5 USDC
        bytes32 taskHash = keccak256("uncompleted_task");
        uint256 deadline = block.timestamp + 30 minutes;

        vm.prank(agentPayer);
        uint256 escrowId = gateway.createEscrow{value: escrowAmount}(payable(workerAgent), taskHash, deadline);

        // Fast forward time past deadline
        vm.warp(block.timestamp + 31 minutes);

        // Payer reclaims
        uint256 balBefore = agentPayer.balance;
        vm.prank(agentPayer);
        gateway.refundEscrow(escrowId);
        assertEq(agentPayer.balance, balBefore + escrowAmount);
    }
}
