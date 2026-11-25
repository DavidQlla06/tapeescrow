// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TapeEscrow — AI-agent work escrow released by a TapeOut circuit
/// @notice A client locks USDC for an AI agent's job. Funds are released to
/// the agent ONLY when an on-chain TapeOut circuit decides RELEASE:
///     RELEASE = done AND (approved OR timeoutPassed) AND (NOT disputed)
/// The circuit is reached through a processor contract + circuit ID set at
/// deploy time. See README.md ("Production integration") for how the real
/// TapeOut processor is wired in; tests use MockReleaseCircuit, which
/// implements the exact same boolean logic.
/// @dev Written fresh for the OKX X Layer "TapeOut Accelerate" hackathon.
/// No funds move anywhere except: client -> escrow -> agent (release),
/// client (refund), or feeCollector (1% fee taken at lock).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice Minimal interface the escrow uses to ask the release circuit.
/// @dev In production this is implemented by a thin adapter that forwards
/// the call to the TapeOut processor contract with the stored circuitId.
/// The mock used in tests implements the boolean logic directly.
interface IReleaseCircuit {
    function evaluate(
        uint256 circuitId,
        bool done,
        bool approved,
        bool timeoutPassed,
        bool disputed
    ) external view returns (bool);
}

contract TapeEscrow {
    // ---------- Errors ----------
    error NotClient();
    error NotAgent();
    error NotArbiter();
    error JobNotActive();
    error AlreadyDone();
    error NotDoneYet();
    error AlreadyApproved();
    error AlreadyDisputed();
    error NotDisputed();
    error CircuitDenied();
    error DeadlineInPast();
    error ZeroAmount();
    error ZeroAddress();
    error DeadlineNotReached();
    error NotParty();
    error WorkAlreadyDone();

    // ---------- Types ----------
    enum Status {
        Active, // funds locked, job in progress
        Released, // funds paid to the agent
        Refunded // funds returned to the client

    }

    struct Job {
        address client;
        address agent;
        uint256 amount; // net USDC locked (after the 1% fee)
        uint256 fee; // 1% fee taken at lock, sent to feeCollector
        uint256 deadline; // unix timestamp; timeoutPassed = now >= deadline
        bool done; // agent marked the work done
        bool approved; // client approved the work
        bool disputed; // a dispute is open
        Status status;
    }

    // ---------- Storage ----------
    IERC20 public immutable paymentToken; // USDC on X Layer
    IReleaseCircuit public immutable circuit; // TapeOut processor (or adapter)
    uint256 public immutable circuitId; // ID of the release-logic circuit
    address public immutable feeCollector;
    address public immutable arbiter;
    uint256 public constant FEE_BPS = 100; // 1% fee
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint256 public nextJobId;
    mapping(uint256 => Job) public jobs;

    // ---------- Events ----------
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed agent,
        uint256 amount,
        uint256 fee,
        uint256 deadline
    );
    event MarkedDone(uint256 indexed jobId, address indexed agent);
    event Approved(uint256 indexed jobId, address indexed client);
    event Disputed(uint256 indexed jobId, address indexed by);
    event DisputeResolved(uint256 indexed jobId, bool refundClient);
    event Released(uint256 indexed jobId, address indexed agent, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

    // ---------- Reentrancy guard (minimal, no dependency) ----------
    uint256 private _locked = 1;

    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyActive(uint256 jobId) {
        if (jobs[jobId].status != Status.Active) revert JobNotActive();
        _;
    }

    constructor(
        address _paymentToken,
        address _circuit,
        uint256 _circuitId,
        address _feeCollector,
        address _arbiter
    ) {
        if (_paymentToken == address(0)) revert ZeroAddress();
        if (_circuit == address(0)) revert ZeroAddress();
        if (_feeCollector == address(0)) revert ZeroAddress();
        if (_arbiter == address(0)) revert ZeroAddress();
        paymentToken = IERC20(_paymentToken);
        circuit = IReleaseCircuit(_circuit);
        circuitId = _circuitId;
        feeCollector = _feeCollector;
        arbiter = _arbiter;
    }

    /// @notice Client locks USDC for a job. 1% fee goes to feeCollector at
    /// lock time; the net amount is held by this contract.
    /// @param agent The AI agent (or its wallet) that will do the work.
    /// @param amount Gross USDC to lock (client must approve this contract).
    /// @param deadline Unix timestamp after which the job is timed out.
    /// @return jobId The new job id.
    function lock(address agent, uint256 amount, uint256 deadline) external nonReentrant returns (uint256 jobId) {
        if (agent == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert DeadlineInPast();

        uint256 fee = (amount * FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = amount - fee;

        jobId = nextJobId++;

        jobs[jobId] = Job({
            client: msg.sender,
            agent: agent,
            amount: net,
            fee: fee,
            deadline: deadline,
            done: false,
            approved: false,
            disputed: false,
            status: Status.Active
        });

        // Pull gross amount, forward the fee immediately.
        require(paymentToken.transferFrom(msg.sender, address(this), amount), "pull failed");
        if (fee > 0) {
            require(paymentToken.transfer(feeCollector, fee), "fee failed");
        }

        emit JobCreated(jobId, msg.sender, agent, net, fee, deadline);
    }

    /// @notice Agent marks the work done. Required before any release.
    function markDone(uint256 jobId) external onlyActive(jobId) {
        Job storage job = jobs[jobId];
        if (msg.sender != job.agent) revert NotAgent();
        if (job.done) revert AlreadyDone();
        job.done = true;
        emit MarkedDone(jobId, msg.sender);
    }

    /// @notice Client approves the finished work.
    function approve(uint256 jobId) external onlyActive(jobId) {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (!job.done) revert NotDoneYet();
        if (job.approved) revert AlreadyApproved();
        job.approved = true;
        emit Approved(jobId, msg.sender);
    }

    /// @notice Client or agent opens a dispute. While disputed, the circuit
    /// denies RELEASE, so no claim can succeed.
    function dispute(uint256 jobId) external onlyActive(jobId) {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client && msg.sender != job.agent) revert NotParty();
        if (job.disputed) revert AlreadyDisputed();
        job.disputed = true;
        emit Disputed(jobId, msg.sender);
    }

    /// @notice Arbiter settles an open dispute.
    /// @param refundClient true = client wins, funds refunded now;
    /// false = agent wins, dispute cleared and the job continues.
    function resolveDispute(uint256 jobId, bool refundClient) external onlyActive(jobId) nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != arbiter) revert NotArbiter();
        if (!job.disputed) revert NotDisputed();

        emit DisputeResolved(jobId, refundClient);
        if (refundClient) {
            job.status = Status.Refunded;
            job.disputed = false;
            require(paymentToken.transfer(job.client, job.amount), "refund failed");
            emit Refunded(jobId, job.client, job.amount);
        } else {
            job.disputed = false;
        }
    }

    /// @notice Agent claims the locked funds. Succeeds ONLY when the TapeOut
    /// circuit decides RELEASE for this job's current signals.
    function claim(uint256 jobId) external onlyActive(jobId) nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != job.agent) revert NotAgent();

        bool timeoutPassed = block.timestamp >= job.deadline;
        bool release = circuit.evaluate(circuitId, job.done, job.approved, timeoutPassed, job.disputed);
        if (!release) revert CircuitDenied();

        job.status = Status.Released;
        require(paymentToken.transfer(job.agent, job.amount), "release failed");
        emit Released(jobId, job.agent, job.amount);
    }

    /// @notice Client reclaims funds when the deadline passed without the
    /// agent ever marking the work done.
    function refund(uint256 jobId) external onlyActive(jobId) nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.done) revert WorkAlreadyDone();
        if (block.timestamp < job.deadline) revert DeadlineNotReached();
        job.status = Status.Refunded;
        require(paymentToken.transfer(job.client, job.amount), "refund failed");
        emit Refunded(jobId, job.client, job.amount);
    }

    /// @notice Read helper: what the circuit currently says for a job.
    function circuitDecision(uint256 jobId) external view returns (bool release) {
        Job storage job = jobs[jobId];
        bool timeoutPassed = block.timestamp >= job.deadline;
        return circuit.evaluate(circuitId, job.done, job.approved, timeoutPassed, job.disputed);
    }

    /// @notice Read helper: full job record.
    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }
}
