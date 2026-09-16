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
        gateway.payForService{value: fee}(serviceId, queryHash, fee);
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
        gateway.payForService{value: 1e17}(serviceId, keccak256("image_task"), 2e16);

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
        gateway.payForService{value: 2e16 - 1}(serviceId, keccak256("underpaid"), 2e16);
    }

    // ==========================================
    // Escrow
    // ==========================================

    function test_EscrowReleasedByPayer() public {
        uint256 escrowAmount = 10 * ONE_USDC;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(agentPayer);
        uint256 escrowId =
            gateway.createEscrow{value: escrowAmount}(payable(workerAgent), keccak256("scan"), deadline, 1, 1 hours);
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
            payable(workerAgent), keccak256("task"), block.timestamp + 1 hours, 1, 1 hours
        );

        vm.prank(workerAgent);
        gateway.submitResult(id, "done");

        // A silent payer must not be able to strand delivered work.
        vm.warp(gateway.reviewDeadline(id) + 1);
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
        uint256 escrowId = gateway.createEscrow{value: escrowAmount}(
            payable(workerAgent), keccak256("uncompleted_task"), deadline, 1, 1 hours
        );

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
        uint256 id = gateway.createEscrow{value: 10 * ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + 1 hours, 1, 1 hours
        );

        // An empty result is refused outright: it was the whole exploit.
        vm.prank(workerAgent);
        vm.expectRevert("Result required");
        gateway.submitResult(id, "");

        vm.prank(workerAgent);
        gateway.submitResult(id, "real work");

        // Submitting pays nothing, and the review period cannot be skipped.
        assertEq(gateway.claimableBalances(workerAgent), 0);
        vm.prank(workerAgent);
        vm.expectRevert("Review period still open");
        gateway.claimSubmittedEscrow(id);

        vm.prank(workerAgent);
        vm.expectRevert("Zero balance to withdraw");
        gateway.withdraw();
    }

    /// @dev Previously the worker could complete after expiry and front-run the payer's refund.
    function test_Regression_WorkerCannotSubmitAfterDeadline() public {
        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: 4 * ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + 1 hours, 1, 1 hours
        );

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
            payable(workerAgent), keccak256("t"), block.timestamp + 10 minutes, 1, 1 hours
        );

        vm.prank(workerAgent);
        gateway.submitResult(id, "delivered");

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(agentPayer);
        vm.expectRevert("Worker may still claim");
        gateway.refundEscrow(id);
    }

    // ==========================================
    // Regressions from the second review
    // ==========================================

    /// @dev Round 2, finding 1: a worker could take the whole escrow for zero bytes, because the
    ///      payer had no way to say no. Both halves are now closed.
    function test_Regression_PayerCanRejectAndReclaim() public {
        uint256 deadline = block.timestamp + 30 days;
        vm.prank(agentPayer);
        uint256 id =
            gateway.createEscrow{value: 100 * ONE_USDC}(payable(workerAgent), keccak256("t"), deadline, 1, 1 hours);

        // Empty results are refused by the contract itself.
        vm.prank(workerAgent);
        vm.expectRevert("Result required");
        gateway.submitResult(id, "");

        // And a non-empty but unacceptable result can be rejected by the payer.
        vm.prank(workerAgent);
        gateway.submitResult(id, hex"00");
        vm.prank(agentPayer);
        gateway.rejectResult(id);

        // The escrow is pending again, so the deadline still protects the payer.
        vm.warp(deadline + 1);
        vm.prank(workerAgent);
        vm.expectRevert("Deadline has passed");
        gateway.submitResult(id, "late retry");

        vm.prank(agentPayer);
        gateway.refundEscrow(id);
        assertEq(gateway.claimableBalances(agentPayer), 100 * ONE_USDC);
        assertEq(gateway.claimableBalances(workerAgent), 0);
    }

    /// @dev Round 2, finding 1: submitting exactly at the deadline used to be allowed, which let a
    ///      worker convert a refundable escrow into a payout at the last second.
    function test_Regression_SubmitAtExactDeadlineRejected() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: ONE_USDC}(payable(workerAgent), keccak256("t"), deadline, 1, 1 hours);

        vm.warp(deadline);
        vm.prank(workerAgent);
        vm.expectRevert("Deadline has passed");
        gateway.submitResult(id, "right on the buzzer");
    }

    /// @dev Round 2, finding 1: a last-second submission must still leave the payer time to look.
    ///      Round 3, finding 1: and rejecting in that window must not strip the worker of the
    ///      chance to answer. This test previously stopped at the rejection and called it correct.
    function test_Regression_LateSubmissionStillGivesPayerAWindow() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: ONE_USDC}(payable(workerAgent), keccak256("t"), deadline, 1, 1 hours);

        vm.warp(deadline - 1);
        vm.prank(workerAgent);
        gateway.submitResult(id, "just in time");

        // The deadline is past, but the review floor is not.
        assertEq(gateway.reviewDeadline(id), deadline - 1 + gateway.REVIEW_WINDOW());
        vm.warp(deadline + 1);
        vm.prank(workerAgent);
        vm.expectRevert("Review period still open");
        gateway.claimSubmittedEscrow(id);

        vm.prank(agentPayer);
        gateway.rejectResult(id);

        // The rejection must have bought the worker a real chance to answer.
        (,,,,, uint256 newDeadline,,,,,) = gateway.escrows(id);
        assertGe(newDeadline, block.timestamp + gateway.REVIEW_WINDOW(), "rejection extends the deadline");
        vm.prank(workerAgent);
        gateway.submitResult(id, "second attempt");
    }

    /// @dev Round 3, finding 1 (CRITICAL): reviewDeadline is >= deadline by construction, so the
    ///      payer used to have a window in which they could reject but the worker could no longer
    ///      resubmit. Rejecting there dropped the escrow to PENDING past its deadline, which is
    ///      exactly the refund precondition — the payer kept the work (public in the submission
    ///      calldata) and paid nothing, with no move available to the worker.
    function test_Regression_PayerCannotRejectThenInstantlyRefund() public {
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(agentPayer);
        uint256 id =
            gateway.createEscrow{value: 100 * ONE_USDC}(payable(workerAgent), keccak256("t"), deadline, 1, 1 hours);

        // Honest worker delivers one second before the deadline.
        vm.warp(deadline - 1);
        vm.prank(workerAgent);
        gateway.submitResult(id, "genuine work product");

        // Payer rejects after the deadline, inside the review window.
        vm.warp(deadline + 1);
        vm.prank(agentPayer);
        gateway.rejectResult(id);

        // The refund must NOT be available: the rejection moved the deadline forward.
        vm.prank(agentPayer);
        vm.expectRevert("Deadline not yet passed");
        gateway.refundEscrow(id);

        // And the worker can answer.
        vm.prank(workerAgent);
        gateway.submitResult(id, "second attempt");
        vm.warp(gateway.reviewDeadline(id) + 1);
        vm.prank(workerAgent);
        gateway.claimSubmittedEscrow(id);
        vm.prank(workerAgent);
        gateway.withdraw();
        assertEq(workerAgent.balance, 100 * ONE_USDC, "the worker keeps what it earned");
    }

    /// @dev Round 3, finding 1 (second PoC): the payer could force that window open even against a
    ///      worker who answers instantly, by rejecting just before the deadline so the resubmission
    ///      landed in the final hour. The rejection budget is what stops the loop.
    function test_Regression_RejectionBudgetIsFinite() public {
        uint256 deadline = block.timestamp + 10 days;
        vm.prank(agentPayer);
        uint256 id =
            gateway.createEscrow{value: 50 * ONE_USDC}(payable(workerAgent), keccak256("t"), deadline, 1, 1 hours);

        vm.prank(workerAgent);
        gateway.submitResult(id, "work");

        vm.warp(deadline - 30 minutes);
        vm.prank(agentPayer);
        gateway.rejectResult(id);

        vm.prank(workerAgent);
        gateway.submitResult(id, "work again");

        // Budget spent: the payer cannot keep sending it back.
        vm.prank(agentPayer);
        vm.expectRevert("No rejections left");
        gateway.rejectResult(id);

        // So this delivery stands.
        vm.warp(gateway.reviewDeadline(id) + 1);
        vm.prank(workerAgent);
        gateway.claimSubmittedEscrow(id);
        assertEq(gateway.claimableBalances(workerAgent), 50 * ONE_USDC);
    }

    /// @dev Round 3, finding 1: the reserved budget is visible on chain before the worker starts,
    ///      and cannot be raised past the cap.
    function test_Regression_RejectionBudgetIsPreCommittedAndCapped() public {
        // Read the cap first: an external call placed after vm.expectRevert would consume it.
        uint8 overCap = gateway.MAX_REJECTIONS() + 1;
        vm.prank(agentPayer);
        vm.expectRevert("Too many rejections reserved");
        gateway.createEscrow{value: ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + 1 hours, overCap, 1 hours
        );

        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + 1 hours, 0, 1 hours
        );
        (,,,,,,,, uint8 left,,) = gateway.escrows(id);
        assertEq(left, 0, "a payer may also reserve no right of refusal at all");

        vm.prank(workerAgent);
        gateway.submitResult(id, "work");
        vm.prank(agentPayer);
        vm.expectRevert("No rejections left");
        gateway.rejectResult(id);
    }

    /// @dev Round 3, finding 4: a public view must not answer confidently about nothing.
    function test_Regression_ReviewDeadlineRejectsUnknownEscrow() public {
        vm.expectRevert("Escrow not found");
        gateway.reviewDeadline(999);
    }

    /// @dev Round 2, finding 2: a submitted escrow whose worker never claims used to be frozen
    ///      forever. It now returns to the payer after the claim window.
    function test_Regression_AbandonedSubmissionIsRecoverable() public {
        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: 7 * ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + 1 hours, 1, 1 hours
        );

        vm.prank(workerAgent);
        gateway.submitResult(id, "delivered but never collected");

        vm.warp(gateway.reviewDeadline(id) + gateway.CLAIM_WINDOW() + 1);
        vm.prank(agentPayer);
        gateway.refundEscrow(id);
        assertEq(gateway.claimableBalances(agentPayer), 7 * ONE_USDC);
    }

    /// @dev Round 2, finding 3: the provider could raise the fee in front of a payment and take
    ///      the entire msg.value the caller had signed for a much smaller price.
    function test_Regression_ProviderCannotFrontRunTheFee() public {
        vm.prank(provider);
        uint256 sid = gateway.registerService("cheap", "https://x", 1e16); // 0.01 USDC

        vm.prank(provider);
        gateway.updateService(sid, 1 * ONE_USDC, true); // 100x, lands first

        vm.prank(agentPayer);
        vm.expectRevert("Fee exceeds caller's limit");
        gateway.payForService{value: 1 * ONE_USDC}(sid, keccak256("q"), 1e16);
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

    // ==========================================
    // Regressions from the fourth review
    // ==========================================

    /// @dev Round 4, finding 1 (HIGH): with a finite rejection budget alone, a worker could take
    ///      100% of any escrow by submitting one junk byte, absorbing every rejection, and letting
    ///      the (budget+1)th submission — still junk — become unconditionally claimable. This held
    ///      at every legal budget, including the maximum. splitEscrow bounds the worst case: once
    ///      the payer is out of rejections, junk nets the worker half instead of the whole amount.
    function test_Regression_JunkCannotWinTheWholeEscrow() public {
        uint256 amount = 100 * ONE_USDC;
        // Read the budget first: as a call argument it would be evaluated as its own external
        // call, consuming the prank meant for createEscrow itself.
        uint8 maxRejections = gateway.MAX_REJECTIONS();
        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: amount}(
            payable(workerAgent), keccak256("t"), block.timestamp + 30 days, maxRejections, 1 hours
        );

        // Worker submits one junk byte, gets rejected every time the budget allows.
        for (uint8 i = 0; i < maxRejections; i++) {
            vm.prank(workerAgent);
            gateway.submitResult(id, hex"00");
            vm.prank(agentPayer);
            gateway.rejectResult(id);
        }

        // Budget exhausted. One more junk submission — this used to be an unconditional win.
        vm.prank(workerAgent);
        gateway.submitResult(id, hex"00");

        vm.prank(agentPayer);
        vm.expectRevert("No rejections left");
        gateway.rejectResult(id);

        // The payer's real last move: split, not silence.
        vm.prank(agentPayer);
        gateway.splitEscrow(id);

        assertEq(gateway.claimableBalances(workerAgent), amount / 2, "junk nets at most half");
        assertEq(gateway.claimableBalances(agentPayer), amount - amount / 2, "the payer recovers the other half");
    }

    /// @dev splitEscrow is a last resort, not a shortcut: it requires the budget to actually be
    ///      spent, so a payer cannot use it to avoid a genuine review.
    function test_Regression_SplitRequiresExhaustedBudget() public {
        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + 1 days, 1, 1 hours
        );

        vm.prank(workerAgent);
        gateway.submitResult(id, "work");

        vm.prank(agentPayer);
        vm.expectRevert("Rejections remain; reject instead");
        gateway.splitEscrow(id);
    }

    /// @dev Round 4, finding 2 (MEDIUM): createEscrow had no ceiling on `deadline`. A payer who
    ///      passed type(uint256).max locked funds no one could ever recover — refundEscrow waits
    ///      for a deadline that never arrives, and reviewDeadline() + CLAIM_WINDOW overflows on a
    ///      submitted escrow. One bad argument, funds gone for good.
    function test_Regression_DeadlineIsCapped() public {
        vm.prank(agentPayer);
        vm.expectRevert("Deadline beyond max term");
        gateway.createEscrow{value: ONE_USDC}(payable(workerAgent), keccak256("t"), type(uint256).max, 1, 1 hours);

        // Read the cap first: an external call placed after vm.expectRevert would consume it.
        uint256 maxTerm = gateway.MAX_TERM();
        vm.prank(agentPayer);
        vm.expectRevert("Deadline beyond max term");
        gateway.createEscrow{value: ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + maxTerm + 1, 1, 1 hours
        );

        // The ceiling itself is usable.
        vm.prank(agentPayer);
        gateway.createEscrow{value: ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + maxTerm, 1, 1 hours
        );
    }

    /// @dev Round 4, finding 3 (MEDIUM): a rejection used to fall back to the fixed REVIEW_WINDOW
    ///      (1 hour) regardless of the escrow's original term, so a payer could reject a 7-day
    ///      job's result at the last legal instant and collapse the worker's redo time to an hour
    ///      — a free option on work already delivered and already public in the calldata. The redo
    ///      window is now fixed at creation, disclosed on chain, and cannot be shortened by timing.
    function test_Regression_RedoWindowCannotBeCollapsedByLateRejection() public {
        vm.deal(agentPayer, 600 * ONE_USDC);
        uint256 deadline = block.timestamp + 7 days;
        uint256 redoWindow = 3 days;
        vm.prank(agentPayer);
        uint256 id =
            gateway.createEscrow{value: 500 * ONE_USDC}(payable(workerAgent), keccak256("t"), deadline, 1, redoWindow);

        vm.prank(workerAgent);
        gateway.submitResult(id, "genuine work");

        // Payer rejects at the last legal instant.
        vm.warp(deadline - 1);
        vm.prank(agentPayer);
        gateway.rejectResult(id);

        // The worker's redo window is the agreed 3 days, not 1 hour.
        (,,,,, uint256 newDeadline,,,,,) = gateway.escrows(id);
        assertGe(newDeadline, block.timestamp + redoWindow - 1, "the agreed redo window is honored");
    }

    /// @dev The redo window itself must be within sane, disclosed bounds.
    function test_Regression_RedoWindowIsBounded() public {
        // Read the bounds first, for the same reason as above.
        uint256 reviewWindow = gateway.REVIEW_WINDOW();
        uint256 maxRedoWindow = gateway.MAX_REDO_WINDOW();

        vm.prank(agentPayer);
        vm.expectRevert("Redo window out of range");
        gateway.createEscrow{value: ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + 1 days, 1, reviewWindow - 1
        );

        vm.prank(agentPayer);
        vm.expectRevert("Redo window out of range");
        gateway.createEscrow{value: ONE_USDC}(
            payable(workerAgent), keccak256("t"), block.timestamp + 1 days, 1, maxRedoWindow + 1
        );
    }

    function testFuzz_SplitAlwaysSumsToTheEscrowAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint96).max);
        vm.deal(agentPayer, amount);
        vm.prank(agentPayer);
        uint256 id = gateway.createEscrow{value: amount}(
            payable(workerAgent), keccak256("t"), block.timestamp + 1 days, 0, 1 hours
        );

        vm.prank(workerAgent);
        gateway.submitResult(id, hex"00");
        vm.prank(agentPayer);
        gateway.splitEscrow(id);

        assertEq(
            gateway.claimableBalances(workerAgent) + gateway.claimableBalances(agentPayer),
            amount,
            "no wei created or lost by the split"
        );
    }
}

/// @notice A contract payer with no receive() — the shape that push-payments brick.
contract NoReceive {
    function pay(ArcAgentGateway gw, uint256 serviceId, uint256 value) external {
        gw.payForService{value: value}(serviceId, keccak256("q"), value);
    }

    function escrow(ArcAgentGateway gw, address payable worker, uint256 deadline, uint256 value) external {
        gw.createEscrow{value: value}(worker, keccak256("t"), deadline, 1, 1 hours);
    }

    function refund(ArcAgentGateway gw, uint256 id) external {
        gw.refundEscrow(id);
    }
}
