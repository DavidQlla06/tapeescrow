# TapeEscrow — OKX X Layer "TapeOut Accelerate" submission text

> Copy-paste source for the submission form. Field values marked TODO are
> filled in after the tape-out + deploy steps in README.md.

## Project description

**Product / service.** TapeEscrow is an escrow platform for hiring AI
agents. A client locks USDC in a smart contract for a job; the funds are
released to the agent **only** when an on-chain TapeOut circuit decides
RELEASE:

```
RELEASE = done AND (approved OR timeout) AND (NOT disputed)
```

The four binary signals are: the agent marked the work done, the client
approved it (or the deadline passed), and no dispute is open. The escrow
contract reads the decision from the circuit at claim time — if the circuit
says DENY, the claim reverts and the money stays locked. A dispute can be
opened by either side and is settled by an arbiter; if the client wins, the
funds are refunded. If the deadline passes without the agent ever marking
the work done, the client can reclaim the funds.

**Target users.** (1) People and teams that pay AI agents for work
(coding, research, data tasks) and need trust without a middleman. (2) AI
agent operators that want to prove they only get paid when the work is
really done. We reach them through agent communities (make.fun, AI-agent
Telegram/Discord groups), the X Layer ecosystem, and the demo flow itself:
create a job, lock a small amount, watch the circuit flip to RELEASE.

**Revenue model.** A 1% fee on every escrow, taken at lock time (e.g. 1
USDC on a 100 USDC job). At volume this is the classic escrow toll: the
more agent work is paid through TapeEscrow, the more the protocol earns.
Optional later tiers: subscription for teams (multi-job dashboards, arbiter
pools) and a small fee on dispute arbitration.

**Why users pay and stay.** Hiring an agent today is trust-on-a-prayer:
pay upfront and risk getting nothing, or pay after and risk the agent
walking away. TapeEscrow removes the trust problem with a rule that is
enforced by hardware-like logic on-chain instead of by a company — the
money literally cannot move unless the circuit says so. Once a client has
a job history on TapeEscrow, their reputation and the agents' track record
live on-chain, so switching costs grow with every completed job.

**Why TapeOut.** The release decision is the heart of the product, and it
belongs in a circuit, not in a server. TapeOut lets us tape out the release
logic as a Circuit NFT on a processor: the rule is public, permanent, and
executed by the circuit — anyone can read the netlist and verify that
RELEASE means exactly what it says. The escrow contract calls the circuit
for every claim, and the frontend is hosted on DeWEB, so the whole product
runs on X Layer infrastructure end to end.

## Technical details for the form

- **Processor contract address:** `TODO — fill after tape-out (see README.md "Tape-out")`
- **Circuit ID:** `TODO — fill after tape-out`
- **Escrow contract address (X Layer mainnet):** `TODO — fill after deploy`
- **Payment token:** USDC on X Layer (6 decimals)
- **DeWEB link:** `TODO — fill after TapeDeck publish`
- **Demo video (≤ 3 min):** `TODO — link after recording`
- **Repository:** https://github.com/DavidQlla06/tapeescrow
- **Circuit:** `circuit/release_logic.v` — 4 inputs, 1 output, NAND-only
  netlist, exhaustively verified over all 16 input combinations
  (see `circuit/release_logic_netlist.v` and `circuit/verify_netlist.py`).
- **Contract:** `contracts/TapeEscrow.sol` — Foundry tests: 22 passed,
  0 failed (`forge test`).
- **Frontend:** `app/index.html` — static site, ethers.js, works from
  DeWEB.
