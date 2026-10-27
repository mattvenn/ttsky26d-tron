/*
 * Copyright (c) 2026 Matt Venn
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// rf_top for the FPGA build: the same ports and one clock read latency as
// the macro, written so yosys maps it to iCE40 block RAM, one copy per read
// port. No write-through: the core never reads a word in the clock it writes
// it (the builder writes the back line buffer while the display reads the
// front; corner writes happen with the query engine idle).
module rf_top (
    input  wire [31:0] w_data,
    input  wire [ 4:0] w_addr,
    input  wire        w_ena,
    input  wire [ 4:0] ra_addr,
    input  wire [ 4:0] rb_addr,
    output reg  [31:0] ra_data,
    output reg  [31:0] rb_data,
    input  wire        clk
);

  reg [31:0] mem_a[0:31];
  reg [31:0] mem_b[0:31];

  always @(posedge clk) begin
    if (w_ena) begin
      mem_a[w_addr] <= w_data;
      mem_b[w_addr] <= w_data;
    end
    ra_data <= mem_a[ra_addr];
    rb_data <= mem_b[rb_addr];
  end

endmodule
