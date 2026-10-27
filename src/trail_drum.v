/*
 * Copyright (c) 2026 Matt Venn
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// The trail store: 64 corners of 9 bits in a shift register that rotates
// one slot every clock, like a drum memory. Slot `rot` is at the output; it
// is written back at the input as it goes round, or replaced by `wdata` when
// `wr` is held and `rot == wslot` (that cycle is `wack`).
//
// The query engine reads every slot in order anyway, so instead of an
// addressed RAM it waits for the oldest slot to come round. That saves the
// 64-way read mux, the address decode and every flop's write enable, which
// were most of an addressed array's area. A write or the start of a scan
// waits at most 64 clocks (128 for a write: the slot match is decoded a
// clock early and registered, to keep the compare off the paths it gates).
//
// The price on the ASIC is hold: each flop feeds the next directly, and with
// the flow's 0.25 ns clock uncertainty most links need a delay cell. That is
// still smaller than an addressed array's read mux and write enables.
//
// Nothing is reset: the core only reads slots it has written this round.
module trail_drum (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        wr,
    input  wire [5:0]  wslot,
    input  wire [8:0]  wdata,
    output wire        wack,
    output reg  [5:0]  rot,
    output wire [8:0]  out
);

  reg [575:0] drum;
  reg          match;  // wslot comes round next clock

  assign out  = drum[575:567];
  assign wack = wr && match;

  always @(posedge clk) begin
    drum  <= {drum[566:0], wack ? wdata : out};
    rot   <= rst_n ? rot + 6'd1 : 6'd0;
    match <= rst_n && wr && (rot + 6'd1 == wslot);
  end

endmodule
