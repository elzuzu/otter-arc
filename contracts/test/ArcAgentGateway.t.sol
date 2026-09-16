// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ArcAgentGateway} from "../src/ArcAgentGateway.sol";

contract ArcAgentGatewayTest is Test {
    ArcAgentGateway public gateway;
    address public provider = makeAddr("provider");
    address public agentPayer = makeAddr("agentPayer");
    address public workerAgent = makeAddr("workerAgent");

    function setUp() public {
        gateway = new ArcAgentGateway();
        // Give test addresses native USDC (which uses 6 decimals: 100 USDC = 100_000_000 units)
        vm.deal(agentPayer, 100 * 1_000_000);
        vm.deal(provider, 10 * 1_000_000);
    }

    function test_RegisterAndPayService() public {
        // 1. Provider registers a service: 0.05 USDC fee = 50,000 units
        vm.startPrank(provider);
        uint256 fee = 50_000; // 0.05 USDC
        uint256 serviceId = gateway.registerService("Arc-DeepSeek-Agent", "https://api.arcagent.internal/v1", fee);
        assertEq(serviceId, 1);
        vm.stopPrank();

        // 2. Agent calls service and pays exact fee
        vm.startPrank(agentPayer);
        bytes32 queryHash = keccak256("prompt:analyze_liquidity_dex");
        gateway.payForService{value: fee}(serviceId, queryHash);
        vm.stopPrank();

        // Check revenue & provider balance
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
        uint256 serviceId = gateway.registerService("Arc-Fast-OCR", "https://api.ocr.arc/v1", 20_000);

        uint256 payerBalBefore = agentPayer.balance;
        vm.prank(agentPayer);
        // Pay 100_000 when fee is 20_000 (excess 80_000 should be refunded)
        gateway.payForService{value: 100_000}(serviceId, keccak256("image_task"));

        assertEq(agentPayer.balance, payerBalBefore - 20_000);
        assertEq(gateway.claimableBalances(provider), 20_000);
    }

    function test_EscrowWorkflow() public {
        uint256 escrowAmount = 10 * 1_000_000; // 10 USDC
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
        uint256 escrowAmount = 5 * 1_000_000; // 5 USDC
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
