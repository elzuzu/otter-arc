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
        (,,,,,, uint256 totalCalls, uint256 totalRevenue) = gateway.services(serviceId);
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
        // Pay 0.1 USDC when the fee is 0.02 USDC. The 0.08 excess is credited back rather than
        // pushed, so that a contract payer without receive() cannot brick its own call.
        gateway.payForService{value: 1e17}(serviceId, keccak256("image_task"));

        assertEq(gateway.claimableBalances(provider), 2e16, "provider earns exactly the fee");
        assertEq(gateway.claimableBalances(agentPayer), 8e16, "excess is claimable by the payer");

        // Net effect once the payer collects: only the fee has left.
        vm.prank(agentPayer);
        gateway.withdraw();
        assertEq(agentPayer.balance, payerBalBefore - 2e16, "only the fee leaves the payer");
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

    function test_EscrowReleasedByPayer() public {
        uint256 escrowAmount = 10 * ONE_USDC;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(agentPayer);
        uint256 escrowId = gateway.createEscrow{value: escrowAmount}(payable(workerAgent), keccak256("scan"), deadline);
        assertEq(escrowId, 1);

        vm.prank(workerAgent);
        gateway.submitResult(escrowId, "result: arbitrage opportunity found at block 4029");

        // The payer is satisfied and does not have to wait out the review window.
        vm.prank(agentPayer);
        gateway.releaseEscrow(escrowId);

        vm.prank(workerAgent);
        gateway.withdraw();
        assertEq(workerAgent.balance, escrowAmount);
    }

    function test_EscrowClaimableAfterReviewWindow() public {
        uint256 escrowAmount = 3 * ONE_USDC;
        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: escrowAmount}(
            payable(workerAgent), keccak256("task"), block.timestamp + 1 hours
        );

        vm.prank(workerAgent);
        gateway.submitResult(id, "done");

        // A silent payer must not be able to strand delivered work.
        vm.warp(block.timestamp + gateway.REVIEW_WINDOW() + 1);
        vm.prank(workerAgent);
        gateway.claimSubmittedEscrow(id);

        vm.prank(workerAgent);
        gateway.withdraw();
        assertEq(workerAgent.balance, escrowAmount);
    }

    function test_EscrowRefundAfterDeadline() public {
        uint256 escrowAmount = 5 * ONE_USDC;
        uint256 deadline = block.timestamp + 30 minutes;

        vm.prank(agentPayer);
        uint256 escrowId =
            gateway.createEscrow{value: escrowAmount}(payable(workerAgent), keccak256("uncompleted_task"), deadline);

        vm.warp(block.timestamp + 31 minutes);

        uint256 balBefore = agentPayer.balance;
        vm.prank(agentPayer);
        gateway.refundEscrow(escrowId);

        // Refunds are pull, not push.
        assertEq(gateway.claimableBalances(agentPayer), escrowAmount);
        vm.prank(agentPayer);
        gateway.withdraw();
        assertEq(agentPayer.balance, balBefore + escrowAmount);
    }

    // ==========================================
    // Regressions — each of these passed before the escrow was reworked
    // ==========================================

    /// @dev Previously the worker could call completeEscrow in the funding block and take it all.
    function test_Regression_WorkerCannotDrainEscrowInstantly() public {
        vm.prank(agentPayer);
        uint256 id =
            gateway.createEscrow{value: 10 * ONE_USDC}(payable(workerAgent), keccak256("t"), block.timestamp + 1 hours);

        vm.prank(workerAgent);
        gateway.submitResult(id, "");

        // Submitting pays nothing, and the review window is not open to be skipped.
        assertEq(gateway.claimableBalances(workerAgent), 0);
        vm.prank(workerAgent);
        vm.expectRevert("Review window still open");
        gateway.claimSubmittedEscrow(id);

        vm.prank(workerAgent);
        vm.expectRevert("Zero balance to withdraw");
        gateway.withdraw();
    }

    /// @dev Previously the worker could complete after expiry and front-run the payer's refund.
    function test_Regression_WorkerCannotSubmitAfterDeadline() public {
        vm.prank(agentPayer);
        uint256 id =
            gateway.createEscrow{value: 4 * ONE_USDC}(payable(workerAgent), keccak256("t"), block.timestamp + 1 hours);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(workerAgent);
        vm.expectRevert("Deadline has passed");
        gateway.submitResult(id, "too late");

        // The payer's refund is therefore uncontested.
        vm.prank(agentPayer);
        gateway.refundEscrow(id);
        assertEq(gateway.claimableBalances(agentPayer), 4 * ONE_USDC);
    }

    /// @dev Conversely, delivered work cannot be refunded out from under the worker.
    function test_Regression_PayerCannotRefundSubmittedWork() public {
        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: 2 * ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + 10 minutes
        );

        vm.prank(workerAgent);
        gateway.submitResult(id, "delivered");

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agentPayer);
        vm.expectRevert("Escrow already closed");
        gateway.refundEscrow(id);
    }

    /// @dev Previously excess payment and refunds were pushed, bricking any payer without receive().
    function test_Regression_ContractPayerWithoutReceiveIsNotBricked() public {
        NoReceive payer = new NoReceive();
        vm.deal(address(payer), 10 * ONE_USDC);

        vm.prank(provider);
        uint256 serviceId = gateway.registerService("svc", "https://x", 1 * ONE_USDC);

        // Overpays by 3 USDC; the excess must be credited, not pushed back.
        payer.pay(gateway, serviceId, 4 * ONE_USDC);
        assertEq(gateway.claimableBalances(address(payer)), 3 * ONE_USDC);

        // And an expired escrow refunds to the same claimable balance.
        payer.escrow(gateway, payable(workerAgent), block.timestamp + 1 minutes, 2 * ONE_USDC);
        vm.warp(block.timestamp + 2 minutes);
        payer.refund(gateway, 1);
        assertEq(gateway.claimableBalances(address(payer)), 5 * ONE_USDC);
    }

    /// @dev Previously receive() accepted value that no one could ever withdraw.
    function test_Regression_StrayValueIsRejected() public {
        vm.prank(agentPayer);
        (bool ok,) = address(gateway).call{value: 1 * ONE_USDC}("");
        assertFalse(ok, "contract must not silently swallow value");
        assertEq(address(gateway).balance, 0);
    }

    /// @dev Previously a zero-fee service let anyone inflate totalCalls for free.
    function test_Regression_ZeroFeeServiceRejected() public {
        vm.prank(provider);
        vm.expectRevert("Fee must be positive");
        gateway.registerService("free", "https://x", 0);
    }

    function test_NativeBalanceViewIsSafeOffArc() public view {
        // No predeploy exists in a bare test EVM; the view must report that instead of reverting.
        (uint256 native,, uint256 remainder, bool available) = gateway.nativeBalanceAsErc20(agentPayer);
        assertEq(native, agentPayer.balance);
        assertEq(remainder, agentPayer.balance % 1e12);
        assertFalse(available);
    }
}

/// @notice A contract payer with no receive() — the shape that push-payments brick.
contract NoReceive {
    function pay(ArcAgentGateway gw, uint256 serviceId, uint256 value) external {
        gw.payForService{value: value}(serviceId, keccak256("q"));
    }

    function escrow(ArcAgentGateway gw, address payable worker, uint256 deadline, uint256 value) external {
        gw.createEscrow{value: value}(worker, keccak256("t"), deadline);
    }

    function refund(ArcAgentGateway gw, uint256 id) external {
        gw.refundEscrow(id);
    }
}
