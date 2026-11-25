// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/TapeEscrow.sol";
import "./Mocks.sol";

/// @title TapeEscrow tests — every path through the release circuit
/// @notice The mock circuit implements the same logic as circuit/release_logic.v:
/// RELEASE = done AND (approved OR timeoutPassed) AND (NOT disputed).
contract TapeEscrowTest is Test {
    TapeEscrow public escrow;
    MockUSDC public usdc;
    MockReleaseCircuit public circuit;

    address public client = address(0xC11E);
    address public agent = address(0xA6E7);
    address public feeCollector = address(0xFEE);
    address public arbiter = address(0xA8817E);
    address public stranger = address(0x57A6E);

    uint256 public constant CIRCUIT_ID = 1;
    uint256 public constant AMOUNT = 10_000e6; // 10,000 USDC (6 decimals)
    uint256 public constant FEE = 100e6; // 1% of 10,000
    uint256 public constant NET = 9_900e6;

    function setUp() public {
        usdc = new MockUSDC();
        circuit = new MockReleaseCircuit();
        escrow = new TapeEscrow(address(usdc), address(circuit), CIRCUIT_ID, feeCollector, arbiter);

        usdc.mint(client, 1_000_000e6);
        vm.prank(client);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _lockJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = escrow.lock(agent, AMOUNT, block.timestamp + 7 days);
    }

    // ---------- Lock ----------

    function test_LockCreatesJobWithFee() public {
        vm.prank(client);
        uint256 jobId = escrow.lock(agent, AMOUNT, block.timestamp + 7 days);

        TapeEscrow.Job memory job = escrow.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.agent, agent);
        assertEq(job.amount, NET);
        assertEq(job.fee, FEE);
        assertEq(uint256(job.status), uint256(TapeEscrow.Status.Active));
        assertEq(usdc.balanceOf(address(escrow)), NET);
        assertEq(usdc.balanceOf(feeCollector), FEE);
        assertEq(usdc.balanceOf(client), 1_000_000e6 - AMOUNT);
    }

    function test_LockRevertsOnZeroAmount() public {
        vm.prank(client);
        vm.expectRevert(TapeEscrow.ZeroAmount.selector);
        escrow.lock(agent, 0, block.timestamp + 7 days);
    }

    function test_LockRevertsOnZeroAgent() public {
        vm.prank(client);
        vm.expectRevert(TapeEscrow.ZeroAddress.selector);
        escrow.lock(address(0), AMOUNT, block.timestamp + 7 days);
    }

    function test_LockRevertsOnPastDeadline() public {
        vm.prank(client);
        vm.expectRevert(TapeEscrow.DeadlineInPast.selector);
        escrow.lock(agent, AMOUNT, block.timestamp - 1);
    }

    // ---------- Normal flow: lock -> done -> approve -> claim ----------

    function test_NormalFlowClaim() public {
        uint256 jobId = _lockJob();

        vm.prank(agent);
        escrow.markDone(jobId);
        vm.prank(client);
        escrow.approve(jobId);

        assertTrue(escrow.circuitDecision(jobId));

        vm.prank(agent);
        escrow.claim(jobId);

        assertEq(usdc.balanceOf(agent), NET);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(uint256(escrow.getJob(jobId).status), uint256(TapeEscrow.Status.Released));
    }

    // ---------- Timeout flow: done, no approve, deadline passes -> claim ----------

    function test_TimeoutFlowClaim() public {
        uint256 jobId = _lockJob();

        vm.prank(agent);
        escrow.markDone(jobId);

        // Before the deadline, with no approval, the circuit denies.
        assertFalse(escrow.circuitDecision(jobId));
        vm.prank(agent);
        vm.expectRevert(TapeEscrow.CircuitDenied.selector);
        escrow.claim(jobId);

        // After the deadline, timeoutPassed flips the circuit to RELEASE.
        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(escrow.circuitDecision(jobId));

        vm.prank(agent);
        escrow.claim(jobId);
        assertEq(usdc.balanceOf(agent), NET);
    }

    // ---------- Dispute: client wins -> refund ----------

    function test_DisputeClientWinsRefund() public {
        uint256 jobId = _lockJob();

        vm.prank(agent);
        escrow.markDone(jobId);
        vm.prank(client);
        escrow.approve(jobId);

        // Dispute flips the circuit to DENY even though done+approved.
        vm.prank(client);
        escrow.dispute(jobId);
        assertFalse(escrow.circuitDecision(jobId));

        vm.prank(agent);
        vm.expectRevert(TapeEscrow.CircuitDenied.selector);
        escrow.claim(jobId);

        vm.prank(arbiter);
        escrow.resolveDispute(jobId, true); // refund client

        assertEq(usdc.balanceOf(client), 1_000_000e6 - AMOUNT + NET);
        assertEq(uint256(escrow.getJob(jobId).status), uint256(TapeEscrow.Status.Refunded));
    }

    // ---------- Dispute: agent wins -> dispute cleared -> claim works ----------

    function test_DisputeAgentWinsThenClaim() public {
        uint256 jobId = _lockJob();

        vm.prank(agent);
        escrow.markDone(jobId);
        vm.prank(client);
        escrow.approve(jobId);
        vm.prank(agent);
        escrow.dispute(jobId);

        vm.prank(arbiter);
        escrow.resolveDispute(jobId, false); // agent wins, dispute cleared

        assertTrue(escrow.circuitDecision(jobId));
        vm.prank(agent);
        escrow.claim(jobId);
        assertEq(usdc.balanceOf(agent), NET);
    }

    // ---------- Circuit denial cases ----------

    function test_ClaimRevertsWhenDisputed() public {
        uint256 jobId = _lockJob();
        vm.prank(agent);
        escrow.markDone(jobId);
        vm.prank(client);
        escrow.approve(jobId);
        vm.prank(client);
        escrow.dispute(jobId);

        vm.prank(agent);
        vm.expectRevert(TapeEscrow.CircuitDenied.selector);
        escrow.claim(jobId);
    }

    function test_ClaimRevertsWhenNotDone() public {
        uint256 jobId = _lockJob();
        vm.prank(client);
        vm.expectRevert(TapeEscrow.NotDoneYet.selector);
        escrow.approve(jobId); // approve itself requires done

        vm.prank(agent);
        vm.expectRevert(TapeEscrow.CircuitDenied.selector);
        escrow.claim(jobId);
    }

    function test_ClaimRevertsWhenNeitherApprovedNorTimeout() public {
        uint256 jobId = _lockJob();
        vm.prank(agent);
        escrow.markDone(jobId);
        // No approve, deadline not reached -> circuit denies.
        assertFalse(escrow.circuitDecision(jobId));
        vm.prank(agent);
        vm.expectRevert(TapeEscrow.CircuitDenied.selector);
        escrow.claim(jobId);
    }

    // ---------- Refund: timeout without done ----------

    function test_RefundTimeoutWithoutDone() public {
        uint256 jobId = _lockJob();

        // Too early: refund reverts.
        vm.prank(client);
        vm.expectRevert(TapeEscrow.DeadlineNotReached.selector);
        escrow.refund(jobId);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(client);
        escrow.refund(jobId);

        assertEq(usdc.balanceOf(client), 1_000_000e6 - AMOUNT + NET);
        assertEq(uint256(escrow.getJob(jobId).status), uint256(TapeEscrow.Status.Refunded));
    }

    function test_RefundRevertsWhenDone() public {
        uint256 jobId = _lockJob();
        vm.prank(agent);
        escrow.markDone(jobId);
        vm.warp(block.timestamp + 7 days + 1);

        // Work was done: client cannot claw back via refund; the agent
        // claims through the circuit instead (timeout path).
        vm.prank(client);
        vm.expectRevert(TapeEscrow.WorkAlreadyDone.selector);
        escrow.refund(jobId);
    }

    // ---------- Access control ----------

    function test_OnlyAgentCanMarkDone() public {
        uint256 jobId = _lockJob();
        vm.prank(client);
        vm.expectRevert(TapeEscrow.NotAgent.selector);
        escrow.markDone(jobId);
    }

    function test_OnlyClientCanApprove() public {
        uint256 jobId = _lockJob();
        vm.prank(agent);
        escrow.markDone(jobId);
        vm.prank(agent);
        vm.expectRevert(TapeEscrow.NotClient.selector);
        escrow.approve(jobId);
    }

    function test_OnlyArbiterCanResolveDispute() public {
        uint256 jobId = _lockJob();
        vm.prank(client);
        escrow.dispute(jobId);
        vm.prank(stranger);
        vm.expectRevert(TapeEscrow.NotArbiter.selector);
        escrow.resolveDispute(jobId, true);
    }

    function test_OnlyPartyCanDispute() public {
        uint256 jobId = _lockJob();
        vm.prank(stranger);
        vm.expectRevert(TapeEscrow.NotParty.selector);
        escrow.dispute(jobId);
    }

    function test_OnlyAgentCanClaim() public {
        uint256 jobId = _lockJob();
        vm.prank(agent);
        escrow.markDone(jobId);
        vm.prank(client);
        escrow.approve(jobId);
        vm.prank(client);
        vm.expectRevert(TapeEscrow.NotAgent.selector);
        escrow.claim(jobId);
    }

    // ---------- Double-settlement guards ----------

    function test_CannotClaimTwice() public {
        uint256 jobId = _lockJob();
        vm.prank(agent);
        escrow.markDone(jobId);
        vm.prank(client);
        escrow.approve(jobId);
        vm.prank(agent);
        escrow.claim(jobId);

        vm.prank(agent);
        vm.expectRevert(TapeEscrow.JobNotActive.selector);
        escrow.claim(jobId);
    }

    function test_CannotDisputeAfterRelease() public {
        uint256 jobId = _lockJob();
        vm.prank(agent);
        escrow.markDone(jobId);
        vm.prank(client);
        escrow.approve(jobId);
        vm.prank(agent);
        escrow.claim(jobId);

        vm.prank(client);
        vm.expectRevert(TapeEscrow.JobNotActive.selector);
        escrow.dispute(jobId);
    }

    function test_CannotMarkDoneTwice() public {
        uint256 jobId = _lockJob();
        vm.prank(agent);
        escrow.markDone(jobId);
        vm.prank(agent);
        vm.expectRevert(TapeEscrow.AlreadyDone.selector);
        escrow.markDone(jobId);
    }

    // ---------- Circuit truth table (mirrors circuit/release_logic.v) ----------

    function test_MockCircuitTruthTable() public view {
        // done, approved, timeout, disputed -> release
        assertTrue(circuit.evaluate(0, true, true, false, false)); // normal
        assertTrue(circuit.evaluate(0, true, false, true, false)); // timeout
        assertTrue(circuit.evaluate(0, true, true, true, false)); // both
        assertFalse(circuit.evaluate(0, false, true, true, false)); // not done
        assertFalse(circuit.evaluate(0, true, false, false, false)); // neither
        assertFalse(circuit.evaluate(0, true, true, false, true)); // disputed
        assertFalse(circuit.evaluate(0, true, false, true, true)); // disputed
        assertFalse(circuit.evaluate(0, false, false, false, false)); // nothing
    }
}
