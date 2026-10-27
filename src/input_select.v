/*
 * Copyright (c) 2026 Matt Venn
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// The Gamepad Pmod receiver, and whether one is plugged in at all or someone
// is playing from the TT Commander.
//
// The Pmod sends each report as a burst: 24 data bits, each sampled on a
// clock rising edge about 10 us apart, then a latch pulse; it reports on
// change and at least once a second. Controller 2's 12 bits come first, then
// controller 1's, each in the order B Y Select Start Up Down Left Right A X
// L R, a 1 meaning pressed; a controller that isn't there sends all ones.
// (The same protocol as gamepad_pmod.v in the VGA Playground by Pat Deegan,
// but keeping only the buttons Tron uses, picked out by position as they go
// past, instead of storing all 24 bits twice.)
//
// The Commander drives ui_in directly, so with no Pmod its keys 5-7 land on
// the latch, clock and data pins. A report counts if at least 16 clock
// edges came before the latch, none more than ~200 us apart, which no one
// pressing keys can do; buttons are only taken from a full 24 bit one.
//
//   pad: a real report arrived in the last TIMEOUT_FRAMES frames
//   cmd: none has, for TIMEOUT_FRAMES
//
// For TIMEOUT_FRAMES after reset neither is set and the game sees no inputs,
// so speed switches left on can't look like Commander keys.

// The RTL testbench shortens the timeout with +define+PMOD_TIMEOUT_FRAMES.
`ifndef PMOD_TIMEOUT_FRAMES
`define PMOD_TIMEOUT_FRAMES 120
`endif

module input_select #(
    parameter TIMEOUT_FRAMES = `PMOD_TIMEOUT_FRAMES  // 2 s
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       frame_tick,  // once a frame
    input  wire       pmod_clk,
    input  wire       pmod_latch,
    input  wire       pmod_data,
    output wire       pad,
    output wire       cmd,
    // per controller, [0] is controller 1
    output reg  [1:0] present,
    output reg  [1:0] start,
    output reg  [1:0] left,
    output reg  [1:0] right,
    output reg  [1:0] y,
    output reg  [1:0] a
);

  reg [1:0]  clk_s, lat_s, dat_s;  // synchronisers
  reg        clk_d, lat_d;
  reg [4:0]  edges;    // clock edges since the last latch, saturating: the bit position
  reg [12:0] gap;      // clocks since the last clock edge, saturating
  reg [6:0]  since;    // frames since the last real report, saturating
  reg        seen;     // a real report has arrived since reset

  // This report's buttons so far, and whether each controller's bits are all ones.
  reg [1:0]  s_start, s_left, s_right, s_y, s_a, s_ones;

  wire       clk_rise = clk_s[1] && !clk_d;
  wire       lat_rise = lat_s[1] && !lat_d;
  wire       bit_in   = dat_s[1];
  wire       first12  = (edges < 5'd12);                          // controller 2's bits
  wire [3:0] pos      = first12 ? edges[3:0] : edges[3:0] - 4'd12;  // within its 12
  wire       ci       = !first12;                                   // controller 1 is index 0

  always @(posedge clk) begin
    if (!rst_n) begin
      clk_s   <= 2'b0;
      lat_s   <= 2'b0;
      dat_s   <= 2'b0;
      clk_d   <= 1'b0;
      lat_d   <= 1'b0;
      edges   <= 5'd0;
      gap     <= 13'd0;
      since   <= 7'd0;
      seen    <= 1'b0;
      s_ones  <= 2'b11;
      present <= 2'b0;
      start   <= 2'b0;
      left    <= 2'b0;
      right   <= 2'b0;
      y       <= 2'b0;
      a       <= 2'b0;
    end else begin
      clk_s <= {clk_s[0], pmod_clk};
      lat_s <= {lat_s[0], pmod_latch};
      dat_s <= {dat_s[0], pmod_data};
      clk_d <= clk_s[1];
      lat_d <= lat_s[1];

      if (clk_rise) begin
        gap <= 13'd0;
        if (edges != 5'd31) edges <= edges + 5'd1;
        if (edges < 5'd24) begin
          // ci is 1 for the last 12 bits: controller 1, index 0.
          if (!bit_in) begin
            if (ci) s_ones[0] <= 1'b0;
            else s_ones[1] <= 1'b0;
          end
          case (pos)
            4'd1: if (ci) s_y[0]     <= bit_in; else s_y[1]     <= bit_in;
            4'd3: if (ci) s_start[0] <= bit_in; else s_start[1] <= bit_in;
            4'd6: if (ci) s_left[0]  <= bit_in; else s_left[1]  <= bit_in;
            4'd7: if (ci) s_right[0] <= bit_in; else s_right[1] <= bit_in;
            4'd8: if (ci) s_a[0]     <= bit_in; else s_a[1]     <= bit_in;
            default: ;
          endcase
        end
      end else if (gap != 13'h1fff) gap <= gap + 13'd1;
      else begin
        edges  <= 5'd0;  // too slow to be the Pmod
        s_ones <= 2'b11;
      end

      if (lat_rise) begin
        edges  <= 5'd0;
        s_ones <= 2'b11;
        if (edges >= 5'd16) begin
          seen  <= 1'b1;
          since <= 7'd0;
        end
        if (edges == 5'd24) begin
          // An absent controller (all ones) reads as nothing pressed.
          present <= ~s_ones;
          start   <= s_start & ~s_ones;
          left    <= s_left  & ~s_ones;
          right   <= s_right & ~s_ones;
          y       <= s_y     & ~s_ones;
          a       <= s_a     & ~s_ones;
        end
      end else if (frame_tick && since != 7'h7f) since <= since + 7'd1;
    end
  end

  assign pad = seen && (since < TIMEOUT_FRAMES);
  assign cmd = (since >= TIMEOUT_FRAMES);

endmodule
