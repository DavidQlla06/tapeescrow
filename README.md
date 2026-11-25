# TapeEscrow

**Escrow for hiring AI agents — the money only moves when an on-chain circuit says so.**

Built for the [OKX X Layer "TapeOut Accelerate"](https://web3.okx.com/xlayer/build-x-series) hackathon (submit by 7 Dec 2026 23:59 UTC / 8 Dec 2026 07:59 WITA).

A client locks USDC in a smart contract for a job. The funds are released to the agent **only** when a TapeOut circuit decides `RELEASE`:

```
RELEASE = done AND (approved OR timeout) AND (NOT disputed)
```

- `done` — the agent marked the work done
- `approved` — the client approved the finished work
- `timeout` — the deadline passed (`block.timestamp >= deadline`)
- `disputed` — a dispute is currently open

The escrow contract asks the circuit at claim time. If the circuit says DENY, the claim reverts and the money stays locked. No server, no middleman — the release rule is hardware-like logic taped out on-chain.

## How a job flows

1. **Client locks** — `lock(agent, amount, deadline)` pulls USDC (6 decimals) into the escrow. A **1% fee** goes to the fee collector; the net amount is held.
2. **Agent works, then marks done** — `markDone(jobId)`.
3. **Client approves** — `approve(jobId)`. Or the deadline passes without approval (timeout path).
4. **Agent claims** — `claim(jobId)` succeeds only if the circuit evaluates RELEASE for the job's current signals.
5. **Disputes** — either side can open one with `dispute(jobId)`; an arbiter settles it with `resolveDispute(jobId, refundClient)`. If the client wins, funds are refunded.
6. **No-show refund** — if the deadline passes and the agent never marked the work done, the client reclaims with `refund(jobId)`.

`circuitDecision(jobId)` is a free view: it shows what the circuit currently says for a job, so the frontend can display RELEASE/DENY live.

## The circuit

`circuit/release_logic.v` — 4 inputs, 1 output, `RELEASE = done & (approved | timeout) & ~disputed`.

Synthesized with Yosys 0.33 + ABC to a **NAND-only netlist** (`circuit/release_logic_netlist.v`): **3 NAND + 5 NOT = 8 NAND-equivalent gates** (each NOT is a NAND with tied inputs). TapeOut processors are built from NAND gates and LATCHes, so this is exactly the form a processor wants.

### Verification — all 16 input combinations, three independent ways

| Check | Command | Result |
|---|---|---|
| RTL testbench (iverilog) | `iverilog -o /tmp/tb.vvp release_logic.v release_logic_tb.v && vvp /tmp/tb.vvp` | **16/16 PASS** |
| Netlist testbench (iverilog) | `iverilog -o /tmp/tb_net.vvp release_logic_netlist.v release_logic_tb.v && vvp /tmp/tb_net.vvp` | **16/16 PASS** |
| Independent Python evaluation of the netlist file | `python3 verify_netlist.py` | **16/16 PASS** |

Truth table (only 3 combinations release): `done=1, approved=0, timeout=1, disputed=0` → 1; `done=1, approved=1, timeout=0, disputed=0` → 1; `done=1, approved=1, timeout=1, disputed=0` → 1; everything else → 0.

Reproduce the synthesis:

```bash
cd circuit
yosys synth.ys            # needs yosys 0.33 + yosys-abc; writes release_logic_netlist.v
```

> Note: `synth.ys` uses `abc -g NAND`. The `abc -liberty nand.lib` route does **not** work with ABC 0.33 — ABC rejects `nand.lib` ("Library with only 1 cell classes cannot be used": `NAND2` and `NAND2X` share one function, so ABC counts them as a single cell class). `nand.lib` is kept in the repo for reference; the `-g NAND` route is the one that produces the netlist. `verify_netlist.py` parses the assign form Yosys 0.33 `write_verilog` actually emits (`assign Y = ~(A & B);`), as well as `$_NAND_` cell instances.

## Smart contract

`contracts/TapeEscrow.sol` (Solidity 0.8.24, no external dependencies — minimal `IERC20` interface and a reentrancy guard are inlined).

- Constructor: `(_paymentToken, _circuit, _circuitId, _feeCollector, _arbiter)`
  - `_paymentToken`: USDC on X Layer (6 decimals)
  - `_circuit`: TapeOut processor contract address (or a thin adapter implementing `IReleaseCircuit.evaluate(circuitId, done, approved, timeoutPassed, disputed)`)
  - `_circuitId`: ID of the taped-out release-logic circuit
  - `_feeCollector`: receives the 1% fee (`FEE_BPS = 100`)
  - `_arbiter`: settles disputes
- Key functions: `lock`, `markDone`, `approve`, `dispute`, `resolveDispute`, `claim`, `refund`, `circuitDecision` (view), `getJob` (view).

### Tests — 22/22 green

```bash
forge install   # fetch forge-std (submodule) on a fresh clone
forge test      # 22 passed, 0 failed
```

Covered: normal flow (lock → done → approve → claim), timeout flow (done → deadline passes → claim), client-wins dispute → refund, agent-wins dispute → claim, claim reverts when disputed / not done / neither approved nor timed out, refund timeout without done, all access-control reverts, no double-claim, and the mock circuit's full 8-row truth table. Fee check: locking 10,000 USDC takes a 100 USDC fee and locks 9,900 USDC net.

## Frontend

`app/index.html` — a pure static site (ethers.js v6 via CDN, no build step), so it can be published on DeWEB as-is:

- Connect wallet (X Layer mainnet, chain ID **196**), set the escrow contract address
- Approve USDC, lock an escrow, list jobs with a live `circuitDecision()` read
- `markDone` / `approve` / `dispute` / `claim` / `refund` buttons shown per role

Run locally with any static server, e.g. `python3 -m http.server` inside `app/`.

## Tape-out (needs a wallet with OKB on X Layer mainnet)

1. Open [tapeout.net](https://tapeout.net/) and pick an **existing processor** (e.g. the Genesis CPU) — no need to build a processor.
2. Buy transistors for the circuit: **8 gates** (3 NAND + 5 NOT). A reference 3,829-gate circuit on X Layer cost ~0.0023 OKB total, so this tiny circuit is far cheaper.
3. Tape out the netlist in `circuit/release_logic_netlist.v`. Record the **processor contract address** and the **circuit ID** (e.g. `3.2.245`).
4. Fill them into `SUBMISSION.md` and use them as the `_circuit` / `_circuitId` constructor arguments when deploying the escrow.

## Deploy (needs a wallet with OKB on X Layer mainnet)

1. Deploy `TapeEscrow` to X Layer mainnet (chain ID 196) with constructor args `(_paymentToken = USDC on X Layer, _circuit = processor contract address, _circuitId, _feeCollector, _arbiter)`.
2. Verify the contract on the X Layer explorer.
3. Paste the deployed address into the frontend (`app/index.html` → contract address field) and re-publish.
4. Test end-to-end on mainnet with a small amount: lock → done → approve → claim, plus the timeout and dispute paths.

X Layer testnet (chain ID 1952, faucet 0.2 OKB/day at web3.okx.com/xlayer/faucet) can be used for a dry run — but the circuit itself is mainnet-only, so the final tape-out and deploy happen on mainnet.

## Publish to DeWEB (needs a wallet)

1. Install [TapeDeck](https://gettapedeck.com/) (desktop app) and follow its manual: "Upload & Publish an App" with the contents of `app/` (static site, `index.html` at root).
2. The site goes live at a `tape://` address / `{id}-{cpu}.tapekit.org`.
3. Put the DeWEB link in `SUBMISSION.md`.

## Submission

`SUBMISSION.md` holds the copy-paste text for the OKX submission form (Google Form linked from the official event page): product, target users, revenue model (1% escrow fee), why users pay and stay, and why TapeOut. Fields marked `TODO` are filled after tape-out + deploy + DeWEB publish. A demo video (≤ 3 min) is recommended.

## Repo layout

```
contracts/TapeEscrow.sol      escrow contract (Solidity 0.8.24)
test/TapeEscrow.t.sol         Foundry tests (22)
test/Mocks.sol                MockReleaseCircuit + MockUSDC (6 decimals)
circuit/release_logic.v       release-logic circuit (Verilog)
circuit/release_logic_netlist.v   NAND-only netlist (Yosys + ABC)
circuit/release_logic_tb.v    exhaustive 16-combination testbench
circuit/verify_netlist.py     independent Python check of the netlist file
circuit/synth.ys              Yosys synthesis script
circuit/cells_sim.v           iverilog models for Yosys internal cells
circuit/nand.lib              reference Liberty library (see note above)
app/index.html                static frontend (X Layer chain 196, USDC)
SUBMISSION.md                 OKX submission form text (TODOs to fill)
LICENSE                       MIT
```

## License

MIT — see `LICENSE`.
