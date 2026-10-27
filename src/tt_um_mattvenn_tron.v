/*
 * Copyright (c) 2026 Matt Venn
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Pin mapping only; the game is in tron.v.
//
// ui_in[6:4]  Gamepad Pmod (latch, clock, data), up to two SNES controllers
// ui_in[1:0]  speed: 0 = 10, 1 = 15, 2 = 8.6, 3 = 60 moves/s (simulation)
// uo_out      Tiny VGA Pmod
//
// Two players share each controller and each needs only two buttons:
//   player 0 (cyan)    controller 1 D-pad left / right
//   player 1 (orange)  controller 1 Y / A
//   player 2 (magenta) controller 2 D-pad left / right
//   player 3 (lime)    controller 2 Y / A
// Start on either controller starts a round.
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

  wire [1:0] pad_b, pad_y, pad_select, pad_start, pad_up, pad_down;
  wire [1:0] pad_left, pad_right, pad_a, pad_x, pad_l, pad_r, pad_present;

  gamepad_pmod_dual gamepad (
      .rst_n     (rst_n),
      .clk       (clk),
      .pmod_data (ui_in[6]),
      .pmod_clk  (ui_in[5]),
      .pmod_latch(ui_in[4]),
      .b         (pad_b),
      .y         (pad_y),
      .select    (pad_select),
      .start     (pad_start),
      .up        (pad_up),
      .down      (pad_down),
      .left      (pad_left),
      .right     (pad_right),
      .a         (pad_a),
      .x         (pad_x),
      .l         (pad_l),
      .r         (pad_r),
      .is_present(pad_present)
  );

  wire [1:0] r, g, b;
  wire hsync, vsync;

  tron core (
      .clk      (clk),
      .rst_n    (rst_n),
      .speed    (ui_in[1:0]),
      .btn_left_in ({pad_y[1], pad_left[1], pad_y[0], pad_left[0]}),
      .btn_right_in({pad_a[1], pad_right[1], pad_a[0], pad_right[0]}),
      .btn_start_in(|pad_start),
      .present_in  ({pad_present[1], pad_present[1], pad_present[0], pad_present[0]}),
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

  wire _unused = &{ena, ui_in[7], ui_in[3:2], uio_in, pad_b, pad_select, pad_up,
                   pad_down, pad_x, pad_l, pad_r, 1'b0};

endmodule
