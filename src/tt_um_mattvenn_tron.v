/*
 * Copyright (c) 2026 Matt Venn
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Pin mapping and choosing the controls; the game is in tron.v.
//
// uo_out      Tiny VGA Pmod
// ui_in[1:0]  speed, read while in reset: 0 = 10, 1 = 15, 2 = 8.6,
//             3 = 60 moves/s (for simulation)
//
// With a Gamepad Pmod (latch, clock, data on ui_in[6:4]), two players share
// each SNES controller, two buttons each. Start on either one starts a round.
//   player 0 (cyan)    controller 1 D-pad left / right
//   player 1 (orange)  controller 1 Y / A
//   player 2 (magenta) controller 2 D-pad left / right
//   player 3 (lime)    controller 2 Y / A
//
// With no Pmod, the TT Commander's keys 1-8 (ui_in[0..7]) in momentary mode,
// two per player, left then right: 1 2 cyan, 3 4 orange, 5 6 magenta,
// 7 8 lime. A player pressing both their keys at once is Start.
// input_select.v tells the two apart.
module tt_um_mattvenn_tron (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  wire pad_mode, cmd_mode, frame_tick;
  wire [1:0] pad_present, pad_start, pad_left, pad_right, pad_y, pad_a;

  input_select sel (
      .clk       (clk),
      .rst_n     (rst_n),
      .frame_tick(frame_tick),
      .pmod_clk  (ui_in[5]),
      .pmod_latch(ui_in[4]),
      .pmod_data (ui_in[6]),
      .pad       (pad_mode),
      .cmd       (cmd_mode),
      .present   (pad_present),
      .start     (pad_start),
      .left      (pad_left),
      .right     (pad_right),
      .y         (pad_y),
      .a         (pad_a)
  );

  // Commander keys, synchronised.
  reg [7:0] keys_s, keys;
  reg [1:0] speed;
  always @(posedge clk) begin
    keys_s <= ui_in;
    keys   <= keys_s;
    if (!rst_n) speed <= ui_in[1:0];
  end
  wire [3:0] key_l = {keys[6], keys[4], keys[2], keys[0]};
  wire [3:0] key_r = {keys[7], keys[5], keys[3], keys[1]};

  wire [3:0] btn_left =
      pad_mode ? {pad_y[1], pad_left[1], pad_y[0], pad_left[0]} :
      cmd_mode ? key_l : 4'b0;
  wire [3:0] btn_right =
      pad_mode ? {pad_a[1], pad_right[1], pad_a[0], pad_right[0]} :
      cmd_mode ? key_r : 4'b0;
  wire btn_start = pad_mode ? |pad_start : cmd_mode ? |(key_l & key_r) : 1'b0;
  wire [3:0] present =
      pad_mode ? {pad_present[1], pad_present[1], pad_present[0], pad_present[0]} :
      cmd_mode ? 4'b1111 : 4'b0;

  wire [1:0] r, g, b;
  wire hsync, vsync;

  tron core (
      .clk      (clk),
      .rst_n    (rst_n),
      .speed    (speed),
      .btn_left_in (btn_left),
      .btn_right_in(btn_right),
      .btn_start_in(btn_start),
      .present_in  (present),
      .input_mode  ({cmd_mode, pad_mode}),
      .frame_tick  (frame_tick),
      .hsync    (hsync),
      .vsync    (vsync),
      .r        (r),
      .g        (g),
      .b        (b)
  );

  // Tiny VGA Pmod pinout
  assign uo_out  = {hsync, b[0], g[0], r[0], vsync, b[1], g[1], r[1]};
  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;

  wire _unused = &{ena, uio_in, 1'b0};

endmodule
