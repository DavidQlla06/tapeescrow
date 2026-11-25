// SPDX-License-Identifier: MIT
// release_logic.v — TapeEscrow release circuit (TapeOut, OKX X Layer)
// ------------------------------------------------------------------
// Boolean function (4 inputs, 1 output):
//     RELEASE = done AND (approved OR timeout) AND (NOT disputed)
//
//   done     = the agent marked the work done
//   approved = the client approved the finished work
//   timeout  = block.timestamp >= job deadline
//   disputed = a dispute is currently open
//
// Truth table (done, approved, timeout, disputed -> release):
//   1 1 x 0 -> 1   (normal: done + approved, no dispute)
//   1 0 1 0 -> 1   (timeout: done + deadline passed, no dispute)
//   1 1 1 0 -> 1   (both approval and timeout)
//   everything else -> 0
//
// Synthesis: Yosys + ABC, mapped to NAND-only cells, because TapeOut
// processors are built from NAND gates and LATCHes:
//     yosys -p "read_verilog release_logic.v; synth; abc -g NAND; \
//                write_verilog release_logic_netlist.v"
// The resulting netlist is verified exhaustively (all 16 input
// combinations) by circuit/release_logic_tb.v (iverilog) and by
// circuit/verify_netlist.py (independent Python evaluation of the
// synthesized netlist file itself).
`default_nettype none

module release_logic (
    input  wire done,
    input  wire approved,
    input  wire timeout,
    input  wire disputed,
    output wire release_out
);

    assign release_out = done & (approved | timeout) & ~disputed;

endmodule

`default_nettype wire
