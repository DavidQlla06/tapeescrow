// SPDX-License-Identifier: MIT
// release_logic_tb.v — exhaustive testbench for release_logic
// Tries all 16 input combinations and checks the output against the
// expected truth table. Run with:
//     iverilog -o /tmp/tb.vvp release_logic.v release_logic_tb.v && vvp /tmp/tb.vvp
// The same testbench can be run against the synthesized NAND netlist:
//     iverilog -o /tmp/tb_net.vvp release_logic_netlist.v release_logic_tb.v && vvp /tmp/tb_net.vvp
// (the netlist module has the same port list; $_NAND_ cells are mapped by
//  the `cells_sim.v` shim included below via `include, or use Yosys `sim`.)
`default_nettype none
`timescale 1ns / 1ps

module release_logic_tb;
    reg done_r;
    reg approved_r;
    reg timeout_r;
    reg disputed_r;
    wire release_out_w;

    release_logic dut (
        .done(done_r),
        .approved(approved_r),
        .timeout(timeout_r),
        .disputed(disputed_r),
        .release_out(release_out_w)
    );

    reg expected_r;
    integer i;
    integer errors;

    initial begin
        errors = 0;
        for (i = 0; i < 16; i = i + 1) begin
            done_r     = i[3];
            approved_r = i[2];
            timeout_r  = i[1];
            disputed_r = i[0];
            expected_r = done_r & (approved_r | timeout_r) & ~disputed_r;
            #10;
            if (release_out_w !== expected_r) begin
                $display("FAIL i=%0d done=%b approved=%b timeout=%b disputed=%b -> got %b, expected %b",
                         i, done_r, approved_r, timeout_r, disputed_r, release_out_w, expected_r);
                errors = errors + 1;
            end else begin
                $display("PASS i=%0d done=%b approved=%b timeout=%b disputed=%b -> %b",
                         i, done_r, approved_r, timeout_r, disputed_r, release_out_w);
            end
        end
        if (errors == 0)
            $display("ALL 16 COMBINATIONS PASS");
        else
            $display("FAILURES: %0d / 16", errors);
        $finish;
    end
endmodule

`default_nettype wire
