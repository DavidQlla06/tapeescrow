// SPDX-License-Identifier: MIT
// cells_sim.v — simulation models for the Yosys internal cells that can
// appear in the synthesized NAND-only netlist (release_logic_netlist.v).
// Lets iverilog simulate the netlist directly:
//   iverilog -o /tmp/tb_net.vvp release_logic_netlist.v cells_sim.v release_logic_tb.v
//   vvp /tmp/tb_net.vvp
`default_nettype none

module $_NAND_ (output Y, input A, input B);
    assign Y = ~(A & B);
endmodule

module $_NOT_ (output Y, input A);
    assign Y = ~A;
endmodule

`default_nettype wire
