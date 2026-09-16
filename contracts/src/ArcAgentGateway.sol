// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArcDecimals, IArcUsdc} from "./ArcDecimals.sol";

/**
 * @title ArcAgentGateway
 * @author OtterArc Team
 * @notice Native-USDC micro-payment and autonomous escrow gateway built for Arc Mainnet (Chain ID 5042).
 *
 * Key Arc-Native Architecture:
 * 1. Native Gas Asset: USDC is the gas token. At the EVM level it carries **18 decimals**
 *    (`msg.value`, `address.balance`), while the USDC ERC-20 predeploy at
 *    `0x3600000000000000000000000000000000000000` carries **6**. Both views read one and the
 *    same balance, related by a factor of `1e12`. Every amount in this contract is denominated
 *    in native units; see `ArcDecimals` for the conversion and `nativeBalanceAsErc20` for a
 *    live on-chain demonstration of the equality.
 * 2. Pay-per-Call: Direct micro-payments for autonomous AI agent tool execution, settled with
 *    `msg.value` and no ERC-20 approval round-trip.
 * 3. Micro-Escrow: Time-locked autonomous escrows for asynchronous agent workflows.
 * 4. Pull-over-Push Security: Reentrancy protection with isolated provider balances.
 */
contract ArcAgentGateway {
    using ArcDecimals for uint256;

    /// @notice Decimals of Arc's native gas asset as seen by `msg.value`.
    uint8 public constant NATIVE_DECIMALS = ArcDecimals.NATIVE_DECIMALS;

    /// @notice Decimals of the USDC ERC-20 predeploy on Arc.
    uint8 public constant ERC20_DECIMALS = ArcDecimals.ERC20_DECIMALS;

    /// @notice Ratio between the native and ERC-20 representations (10 ** 12).
    uint256 public constant SCALE = ArcDecimals.SCALE;

    /// @notice Canonical USDC ERC-20 predeploy address on Arc Mainnet.
    address public constant USDC_ERC20 = ArcDecimals.USDC_ERC20;

    /// @notice One USDC expressed in native units (18 decimals).
    uint256 public constant ONE_USDC = 1e18;

    struct Service {
        uint256 id;
        address payable provider;
        string name;
        string endpoint;
        uint256 fee; // native units (18 decimals); 1 USDC == ONE_USDC == 1e18
        bool active;
        uint256 totalCalls;
        uint256 totalRevenue;
    }

    enum EscrowStatus { PENDING, COMPLETED, REFUNDED }

    struct Escrow {
        uint256 id;
        address payer;
        address payable worker;
        uint256 amount;
        bytes32 taskHash;
        uint256 deadline;
        EscrowStatus status;
        bytes resultData;
    }

    address public immutable protocolOwner;
    uint256 public serviceCounter;
    uint256 public escrowCounter;

    // Service storage
    mapping(uint256 => Service) public services;
    // Escrow storage
    mapping(uint256 => Escrow) public escrows;
    // Provider claimable balances (pull pattern)
    mapping(address => uint256) public claimableBalances;

    // Events
    event ServiceRegistered(uint256 indexed serviceId, address indexed provider, string name, uint256 fee);
    event ServiceUpdated(uint256 indexed serviceId, uint256 newFee, bool active);
    event ServicePaid(
        uint256 indexed serviceId,
        address indexed payer,
        address indexed provider,
        uint256 amount,
        bytes32 queryHash
    );
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed payer,
        address indexed worker,
        uint256 amount,
        bytes32 taskHash,
        uint256 deadline
    );
    event EscrowCompleted(uint256 indexed escrowId, address indexed worker, bytes resultData);
    event EscrowRefunded(uint256 indexed escrowId, address indexed payer, uint256 amount);
    event FundsWithdrawn(address indexed recipient, uint256 amount);

    // Reentrancy guard
    uint256 private _status;
    modifier nonReentrant() {
        require(_status != 2, "ReentrancyGuard: reentrant call");
        _status = 2;
        _;
        _status = 1;
    }

    modifier onlyServiceOwner(uint256 serviceId) {
        require(services[serviceId].provider == msg.sender, "Caller is not service provider");
        _;
    }

    constructor() {
        protocolOwner = msg.sender;
        _status = 1;
    }

    // ==========================================
    // 1. AGENT SERVICE REGISTRY & PAY-PER-CALL
    // ==========================================

    /**
     * @notice Register a new agent service or micro-API endpoint.
     * @param name Human-readable service name (e.g. "Arc-LLM-Inference-Fast")
     * @param endpoint URL or decentralized ID
     * @param fee Price per invocation in native units (18 decimals), e.g. 5e15 = 0.005 USDC
     */
    function registerService(
        string calldata name,
        string calldata endpoint,
        uint256 fee
    ) external returns (uint256 serviceId) {
        require(bytes(name).length > 0, "Name required");
        serviceId = ++serviceCounter;

        services[serviceId] = Service({
            id: serviceId,
            provider: payable(msg.sender),
            name: name,
            endpoint: endpoint,
            fee: fee,
            active: true,
            totalCalls: 0,
            totalRevenue: 0
        });

        emit ServiceRegistered(serviceId, msg.sender, name, fee);
    }

    /**
     * @notice Update service fee and active status.
     */
    function updateService(
        uint256 serviceId,
        uint256 newFee,
        bool active
    ) external onlyServiceOwner(serviceId) {
        services[serviceId].fee = newFee;
        services[serviceId].active = active;
        emit ServiceUpdated(serviceId, newFee, active);
    }

    /**
     * @notice Pay for an agent service with native USDC.
     * @param serviceId Target service identifier
     * @param queryHash Hash of the request payload or prompt
     */
    function payForService(uint256 serviceId, bytes32 queryHash) external payable nonReentrant {
        Service storage s = services[serviceId];
        require(s.id != 0, "Service does not exist");
        require(s.active, "Service is not active");
        require(msg.value >= s.fee, "Insufficient native USDC sent");

        s.totalCalls += 1;
        s.totalRevenue += s.fee;
        claimableBalances[s.provider] += s.fee;

        // Refund any excess USDC sent
        uint256 refund = msg.value - s.fee;
        if (refund > 0) {
            (bool success, ) = payable(msg.sender).call{value: refund}("");
            require(success, "Refund transfer failed");
        }

        emit ServicePaid(serviceId, msg.sender, s.provider, s.fee, queryHash);
    }

    // ==========================================
    // 2. AUTONOMOUS AGENT ESCROW
    // ==========================================

    /**
     * @notice Lock USDC in an autonomous escrow for a task to be performed by an AI agent.
     * @param worker Address of the agent performing the task
     * @param taskHash Hash representing task description and parameters
     * @param deadline Unix timestamp after which payer can refund if uncompleted
     */
    function createEscrow(
        address payable worker,
        bytes32 taskHash,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 escrowId) {
        require(worker != address(0), "Invalid worker");
        require(msg.value > 0, "Must deposit native USDC");
        require(deadline > block.timestamp, "Deadline must be in future");

        escrowId = ++escrowCounter;
        escrows[escrowId] = Escrow({
            id: escrowId,
            payer: msg.sender,
            worker: worker,
            amount: msg.value,
            taskHash: taskHash,
            deadline: deadline,
            status: EscrowStatus.PENDING,
            resultData: ""
        });

        emit EscrowCreated(escrowId, msg.sender, worker, msg.value, taskHash, deadline);
    }

    /**
     * @notice Worker agent submits result and claims escrowed USDC.
     * @dev Payer or worker can trigger settlement once satisfied.
     */
    function completeEscrow(uint256 escrowId, bytes calldata resultData) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.id != 0, "Escrow not found");
        require(e.status == EscrowStatus.PENDING, "Escrow already closed");
        require(msg.sender == e.worker || msg.sender == e.payer, "Unauthorized");

        e.status = EscrowStatus.COMPLETED;
        e.resultData = resultData;
        claimableBalances[e.worker] += e.amount;

        emit EscrowCompleted(escrowId, e.worker, resultData);
    }

    /**
     * @notice Payer reclaims locked funds if deadline has expired without completion.
     */
    function refundEscrow(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.id != 0, "Escrow not found");
        require(e.status == EscrowStatus.PENDING, "Escrow already closed");
        require(msg.sender == e.payer, "Only payer can refund");
        require(block.timestamp > e.deadline, "Deadline not yet passed");

        e.status = EscrowStatus.REFUNDED;
        uint256 amount = e.amount;

        (bool success, ) = payable(e.payer).call{value: amount}("");
        require(success, "Refund failed");

        emit EscrowRefunded(escrowId, e.payer, amount);
    }

    // ==========================================
    // 3. WITHDRAWAL & UTILITIES
    // ==========================================

    /**
     * @notice Withdraw accumulated earnings in native USDC.
     */
    function withdraw() external nonReentrant {
        uint256 amount = claimableBalances[msg.sender];
        require(amount > 0, "Zero balance to withdraw");

        claimableBalances[msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdrawal failed");

        emit FundsWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Arc's two views of one balance, read live and side by side.
     * @dev Returns `account`'s native balance (18 decimals) together with what the USDC ERC-20
     *      predeploy reports for the same account (6 decimals), plus the native remainder that
     *      the 6-decimal view truncates. The invariant `native / 1e12 == erc20` holds for every
     *      account on Arc; `remainder` is what that division discards.
     *      This is the protocol's on-chain proof that it denominates in the correct unit.
     * @return native Balance in native units (18 decimals).
     * @return erc20 Balance as reported by the USDC ERC-20 predeploy (6 decimals).
     * @return remainder Native units discarded by the 6-decimal view, always in [0, 1e12).
     */
    function nativeBalanceAsErc20(address account)
        external
        view
        returns (uint256 native, uint256 erc20, uint256 remainder)
    {
        native = account.balance;
        erc20 = IArcUsdc(USDC_ERC20).balanceOf(account);
        remainder = ArcDecimals.truncationRemainder(native);
    }

    /**
     * @notice Convert a native-denominated amount to ERC-20 USDC units, as the predeploy would.
     */
    function toErc20Units(uint256 nativeAmount) external pure returns (uint256) {
        return ArcDecimals.toErc20Units(nativeAmount);
    }

    /**
     * @notice Convert an ERC-20 USDC amount to native units. Exact, no rounding.
     */
    function toNativeUnits(uint256 erc20Amount) external pure returns (uint256) {
        return ArcDecimals.toNativeUnits(erc20Amount);
    }

    /**
     * @notice View service count.
     */
    function getServiceCount() external view returns (uint256) {
        return serviceCounter;
    }

    /**
     * @notice View escrow count.
     */
    function getEscrowCount() external view returns (uint256) {
        return escrowCounter;
    }

    receive() external payable {
        // Fallback allows funding if needed
    }
}
