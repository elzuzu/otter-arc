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

    enum EscrowStatus {
        PENDING,
        SUBMITTED,
        RELEASED,
        REFUNDED,
        SPLIT
    }

    struct Escrow {
        uint256 id;
        address payer;
        address payable worker;
        uint256 amount;
        bytes32 taskHash;
        uint256 deadline;
        uint256 submittedAt;
        uint256 redoWindow;
        uint8 rejectionsLeft;
        EscrowStatus status;
        bytes resultData;
    }

    /**
     * @notice The minimum time a payer always gets to review a submitted result.
     * @dev The payer's real deadline is `max(escrow.deadline, submittedAt + REVIEW_WINDOW)`: the
     *      deadline they chose, but never less than this much after a submission actually lands.
     *      Without the floor, a worker submitting one second before the deadline would leave the
     *      payer no time to reject. One hour suits agents, which operate at machine speed.
     */
    uint256 public constant REVIEW_WINDOW = 1 hours;

    /**
     * @notice Longest `deadline` an escrow may be CREATED with, measured from creation time.
     * @dev Without this ceiling, `deadline = type(uint256).max` produces an escrow neither party
     *      can ever close — `refundEscrow` waits for a deadline that never arrives, and
     *      `reviewDeadline() + CLAIM_WINDOW` overflows. One bad argument, funds gone for good.
     *
     *      This bounds the *starting* deadline only, not the escrow's total lifetime. Each
     *      `rejectResult` can still push `deadline` forward by up to `redoWindow`, so a fully
     *      contested escrow (`MAX_REJECTIONS` rejections, each near the current deadline, each
     *      extending it by `MAX_REDO_WINDOW`) can run for up to
     *      `MAX_TERM + MAX_REJECTIONS * MAX_REDO_WINDOW` — 365 + 3*30 = 455 days, about 15 months at the current
     *      constants. That is intended: it is what "try again while the deadline allows" means
     *      when taken literally, and it never overflows or strands anything.
     */
    uint256 public constant MAX_TERM = 365 days;

    /// @notice Longest redo window a payer may grant after a rejection.
    uint256 public constant MAX_REDO_WINDOW = 30 days;

    /**
     * @notice Most rejections a payer may reserve when creating an escrow.
     * @dev The budget is fixed at creation and visible on chain, so a worker can read the terms
     *      before spending anything. It is capped because an unbounded right of refusal is not a
     *      review: the payer could refuse forever and win by attrition.
     */
    uint8 public constant MAX_REJECTIONS = 3;

    /**
     * @notice How long a worker has to collect an escrow the payer did not contest.
     * @dev After this, the payer may refund a still-unclaimed submission. Without it, a worker
     *      that loses its key — or that cannot receive value — would freeze the funds forever.
     */
    uint256 public constant CLAIM_WINDOW = 30 days;

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
        uint256 indexed serviceId, address indexed payer, address indexed provider, uint256 amount, bytes32 queryHash
    );
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed payer,
        address indexed worker,
        uint256 amount,
        bytes32 taskHash,
        uint256 deadline,
        uint8 maxRejections,
        uint256 redoWindow
    );
    event EscrowResultSubmitted(
        uint256 indexed escrowId, address indexed worker, bytes resultData, uint256 claimableAt
    );
    event EscrowResultRejected(
        uint256 indexed escrowId, address indexed payer, uint8 rejectionsLeft, uint256 newDeadline
    );
    event EscrowReleased(uint256 indexed escrowId, address indexed worker, uint256 amount, address releasedBy);
    event EscrowRefunded(uint256 indexed escrowId, address indexed payer, uint256 amount);
    event EscrowSplit(uint256 indexed escrowId, address indexed payer, address indexed worker, uint256 half);
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
    function registerService(string calldata name, string calldata endpoint, uint256 fee)
        external
        returns (uint256 serviceId)
    {
        require(bytes(name).length > 0, "Name required");
        // A zero fee would let anyone inflate totalCalls for free, so the registry
        // counters this contract publishes would no longer mean anything.
        require(fee > 0, "Fee must be positive");
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
    function updateService(uint256 serviceId, uint256 newFee, bool active) external onlyServiceOwner(serviceId) {
        require(newFee > 0, "Fee must be positive");
        services[serviceId].fee = newFee;
        services[serviceId].active = active;
        emit ServiceUpdated(serviceId, newFee, active);
    }

    /**
     * @notice Pay for an agent service with native USDC.
     * @dev `maxFee` is the price the caller agreed to. Without it a provider could front-run the
     *      call with `updateService`, raise the fee to the whole `msg.value`, and keep the lot —
     *      the caller having signed for a far smaller number. Pass the fee you read from
     *      `services(serviceId)`; anything charged above it reverts.
     * @param serviceId Target service identifier
     * @param queryHash Hash of the request payload or prompt
     * @param maxFee Highest fee, in native units, the caller is willing to be charged
     */
    function payForService(uint256 serviceId, bytes32 queryHash, uint256 maxFee) external payable nonReentrant {
        Service storage s = services[serviceId];
        require(s.id != 0, "Service does not exist");
        require(s.active, "Service is not active");
        require(s.fee <= maxFee, "Fee exceeds caller's limit");
        require(msg.value >= s.fee, "Insufficient native USDC sent");

        s.totalCalls += 1;
        s.totalRevenue += s.fee;
        claimableBalances[s.provider] += s.fee;

        // Credit any excess back to the payer's claimable balance rather than pushing it. A
        // contract payer with no receive() would otherwise make its own call revert.
        uint256 excess = msg.value - s.fee;
        if (excess > 0) {
            claimableBalances[msg.sender] += excess;
        }

        emit ServicePaid(serviceId, msg.sender, s.provider, s.fee, queryHash);
    }

    // ==========================================
    // 2. AUTONOMOUS AGENT ESCROW
    // ==========================================

    /**
     * @notice Lock USDC in an autonomous escrow for a task to be performed by an AI agent.
     *
     * @dev Every term is fixed here and readable on chain, so a worker can price the job before
     *      spending anything: how long it has, how many times the work can be sent back, and how
     *      long it gets to redo it each time.
     *
     * @param worker Address of the agent performing the task
     * @param taskHash Hash representing task description and parameters
     * @param deadline Unix timestamp the work must be delivered by, at most MAX_TERM from now
     * @param maxRejections How many times the payer may reject a result, at most MAX_REJECTIONS
     * @param redoWindow How long the worker gets to answer a rejection, at most MAX_REDO_WINDOW
     */
    function createEscrow(
        address payable worker,
        bytes32 taskHash,
        uint256 deadline,
        uint8 maxRejections,
        uint256 redoWindow
    ) external payable nonReentrant returns (uint256 escrowId) {
        require(worker != address(0), "Invalid worker");
        require(msg.value > 0, "Must deposit native USDC");
        require(deadline > block.timestamp, "Deadline must be in future");
        require(deadline <= block.timestamp + MAX_TERM, "Deadline beyond max term");
        require(maxRejections <= MAX_REJECTIONS, "Too many rejections reserved");
        require(redoWindow >= REVIEW_WINDOW && redoWindow <= MAX_REDO_WINDOW, "Redo window out of range");

        escrowId = ++escrowCounter;
        escrows[escrowId] = Escrow({
            id: escrowId,
            payer: msg.sender,
            worker: worker,
            amount: msg.value,
            taskHash: taskHash,
            deadline: deadline,
            submittedAt: 0,
            redoWindow: redoWindow,
            rejectionsLeft: maxRejections,
            status: EscrowStatus.PENDING,
            resultData: ""
        });

        emit EscrowCreated(escrowId, msg.sender, worker, msg.value, taskHash, deadline, maxRejections, redoWindow);
    }

    /**
     * @notice The point until which the payer may still reject or release a submitted result.
     * @dev The later of the deadline they chose and REVIEW_WINDOW after the submission landed, so
     *      a last-second submission cannot deprive the payer of a chance to look at it.
     */
    function reviewDeadline(uint256 escrowId) public view returns (uint256) {
        Escrow storage e = escrows[escrowId];
        require(e.id != 0, "Escrow not found");
        uint256 floorTime = e.submittedAt + REVIEW_WINDOW;
        return e.deadline > floorTime ? e.deadline : floorTime;
    }

    /**
     * @notice The worker publishes its result on chain, which opens the payer's review.
     * @dev Submitting pays nothing. An empty result is rejected outright: without that, a worker
     *      could convert a refundable escrow into a claim by sending zero bytes. Submission must
     *      land strictly before the deadline, so a worker cannot wait out the clock and then take
     *      a payout the payer was about to reclaim.
     */
    function submitResult(uint256 escrowId, bytes calldata resultData) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.id != 0, "Escrow not found");
        require(e.status == EscrowStatus.PENDING, "Escrow not pending");
        require(msg.sender == e.worker, "Only worker can submit");
        require(block.timestamp < e.deadline, "Deadline has passed");
        require(resultData.length > 0, "Result required");

        e.status = EscrowStatus.SUBMITTED;
        e.submittedAt = block.timestamp;
        e.resultData = resultData;

        emit EscrowResultSubmitted(escrowId, e.worker, resultData, reviewDeadline(escrowId));
    }

    /**
     * @notice The payer refuses a submitted result, returning the escrow to PENDING.
     *
     * @dev Two properties make this a review rather than a way to take the work for free.
     *
     *      First, a rejection **extends the deadline** to at least REVIEW_WINDOW from now. Without
     *      that, the payer could reject inside the window that `reviewDeadline` opens past the
     *      deadline — a window in which `submitResult` is already closed — and then immediately
     *      refund a result that is permanently public in the submission calldata. The worker would
     *      have delivered and been paid nothing, with no move available.
     *
     *      Second, the number of rejections is fixed when the escrow is created and cannot grow.
     *      Extending the deadline on every rejection, with no budget, would simply move the
     *      dominant strategy: the payer would refuse forever and win by outspending the worker in
     *      gas. Once the budget is spent the next delivery stands.
     */
    function rejectResult(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.id != 0, "Escrow not found");
        require(e.status == EscrowStatus.SUBMITTED, "No result under review");
        require(msg.sender == e.payer, "Only payer can reject");
        require(block.timestamp <= reviewDeadline(escrowId), "Review period is over");
        require(e.rejectionsLeft > 0, "No rejections left");

        e.rejectionsLeft -= 1;
        e.status = EscrowStatus.PENDING;
        e.submittedAt = 0;
        e.resultData = "";

        // The redo window was agreed at creation. Using the one-hour floor here instead would
        // collapse a seven-day job into an hour the moment the payer rejects at the last instant,
        // handing them a free option on work already delivered and already public.
        uint256 minDeadline = block.timestamp + e.redoWindow;
        if (e.deadline < minDeadline) {
            e.deadline = minDeadline;
        }

        emit EscrowResultRejected(escrowId, e.payer, e.rejectionsLeft, e.deadline);
    }

    /**
     * @notice The payer accepts the work and releases the escrow to the worker.
     * @dev Callable at any time before the escrow closes, including before a submission, so a
     *      satisfied payer is never forced to wait.
     */
    function releaseEscrow(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.id != 0, "Escrow not found");
        require(msg.sender == e.payer, "Only payer can release");
        require(e.status == EscrowStatus.PENDING || e.status == EscrowStatus.SUBMITTED, "Escrow already closed");

        e.status = EscrowStatus.RELEASED;
        claimableBalances[e.worker] += e.amount;

        emit EscrowReleased(escrowId, e.worker, e.amount, msg.sender);
    }

    /**
     * @notice The worker collects a result the payer neither released nor rejected in time.
     * @dev Silence pays the worker. This is what stops a payer from taking delivery and then
     *      simply never answering.
     */
    function claimSubmittedEscrow(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.id != 0, "Escrow not found");
        require(e.status == EscrowStatus.SUBMITTED, "No result under review");
        require(msg.sender == e.worker, "Only worker can claim");
        require(block.timestamp > reviewDeadline(escrowId), "Review period still open");

        e.status = EscrowStatus.RELEASED;
        claimableBalances[e.worker] += e.amount;

        emit EscrowReleased(escrowId, e.worker, e.amount, msg.sender);
    }

    /**
     * @notice The payer's last resort once the rejection budget is spent: split the escrow.
     *
     * @dev Every earlier version of this escrow guaranteed one side a way to take the whole
     *      amount for nothing. A finite rejection budget stops the payer from refusing forever,
     *      but by itself it hands the worker a deterministic full payout: submit one junk byte,
     *      absorb every rejection, and the submission after the budget runs out cannot be turned
     *      away. This function is what stops that from being profitable. Once `rejectionsLeft`
     *      reaches zero, the payer's only non-releasing move is no longer silence — it is to cut
     *      the loss in half and end the dispute deterministically.
     *
     *      This does not claim to judge the work; it bounds what either side can extract by being
     *      unreasonable. A worker gambling on junk gets at most half instead of the whole amount,
     *      and a payer who genuinely received nothing usable still recovers half instead of paying
     *      in full for it.
     */
    function splitEscrow(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.id != 0, "Escrow not found");
        require(e.status == EscrowStatus.SUBMITTED, "No result under review");
        require(msg.sender == e.payer, "Only payer can split");
        require(e.rejectionsLeft == 0, "Rejections remain; reject instead");

        e.status = EscrowStatus.SPLIT;
        uint256 workerHalf = e.amount / 2;
        uint256 payerHalf = e.amount - workerHalf; // exact: the two halves always sum to amount
        claimableBalances[e.worker] += workerHalf;
        claimableBalances[e.payer] += payerHalf;

        emit EscrowSplit(escrowId, e.payer, e.worker, workerHalf);
    }

    /**
     * @notice The payer reclaims an escrow that was never delivered, or never collected.
     * @dev Two cases, and between them no escrow can be stranded:
     *      - PENDING past the deadline: nothing was delivered, or everything delivered was
     *        rejected while there was still time to redo it.
     *      - SUBMITTED past the review period plus CLAIM_WINDOW: the worker won the escrow by
     *        default and then never took it, so the value would otherwise sit here forever.
     *      The amount is credited to the payer's claimable balance rather than pushed, so a
     *      contract payer cannot be bricked.
     */
    function refundEscrow(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.id != 0, "Escrow not found");
        require(msg.sender == e.payer, "Only payer can refund");

        if (e.status == EscrowStatus.PENDING) {
            require(block.timestamp > e.deadline, "Deadline not yet passed");
        } else if (e.status == EscrowStatus.SUBMITTED) {
            require(block.timestamp > reviewDeadline(escrowId) + CLAIM_WINDOW, "Worker may still claim");
        } else {
            revert("Escrow already closed");
        }

        e.status = EscrowStatus.REFUNDED;
        claimableBalances[e.payer] += e.amount;

        emit EscrowRefunded(escrowId, e.payer, e.amount);
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
        (bool success,) = payable(msg.sender).call{value: amount}("");
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
     * @return predeployAvailable False off Arc, where nothing is deployed at USDC_ERC20; `erc20`
     *         is then zero and carries no meaning.
     */
    function nativeBalanceAsErc20(address account)
        external
        view
        returns (uint256 native, uint256 erc20, uint256 remainder, bool predeployAvailable)
    {
        native = account.balance;
        remainder = ArcDecimals.truncationRemainder(native);

        // Off Arc — a local anvil, or any other chain — nothing lives at the predeploy address and
        // a plain call would revert. Report that rather than making a read-only view unusable.
        predeployAvailable = USDC_ERC20.code.length > 0;
        if (predeployAvailable) {
            erc20 = IArcUsdc(USDC_ERC20).balanceOf(account);
        }
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
}
