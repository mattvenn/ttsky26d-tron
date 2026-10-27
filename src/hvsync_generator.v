`ifndef HVSYNC_GENERATOR_H
`define HVSYNC_GENERATOR_H

/*
Video sync generator, used to drive a VGA monitor.
Taken from the VGA Playground (src/examples/common/hvsync_generator.v,
https://github.com/TinyTapeout/vga-playground) with two changes:

- The default timing is VESA 800x600@60 (40 MHz pixel clock) rather than
  640x480@60.
- hpos is 11 bits: an 800x600 line is 1056 clocks, which does not fit in 10.

The syncs stay active low like the original. VESA says positive for this
mode, but monitors lock either way (the multi-seg-monitor project ran this
mode active low on real hardware).
*/

module hvsync_generator(clk, reset, hsync, vsync, display_on, hpos, vpos);

  input clk;
  input reset;
  output reg hsync, vsync;
  output display_on;
  output reg [10:0] hpos;
  output reg [9:0] vpos;

  // horizontal constants
  parameter H_DISPLAY       = 800; // horizontal display width
  parameter H_BACK          =  88; // horizontal left border (back porch)
  parameter H_FRONT         =  40; // horizontal right border (front porch)
  parameter H_SYNC          = 128; // horizontal sync width
  // vertical constants
  parameter V_DISPLAY       = 600; // vertical display height
  parameter V_TOP           =  23; // vertical top border
  parameter V_BOTTOM        =   1; // vertical bottom border
  parameter V_SYNC          =   4; // vertical sync # lines
  // derived constants
  parameter H_SYNC_START    = H_DISPLAY + H_FRONT;
  parameter H_SYNC_END      = H_DISPLAY + H_FRONT + H_SYNC - 1;
  parameter H_MAX           = H_DISPLAY + H_BACK + H_FRONT + H_SYNC - 1;
  parameter V_SYNC_START    = V_DISPLAY + V_BOTTOM;
  parameter V_SYNC_END      = V_DISPLAY + V_BOTTOM + V_SYNC - 1;
  parameter V_MAX           = V_DISPLAY + V_TOP + V_BOTTOM + V_SYNC - 1;

  wire hmaxxed = (hpos == H_MAX) || reset;	// set when hpos is maximum
  wire vmaxxed = (vpos == V_MAX) || reset;	// set when vpos is maximum

  // horizontal position counter
  always @(posedge clk)
  begin
    hsync <= ~(hpos>=H_SYNC_START && hpos<=H_SYNC_END);
    if(hmaxxed)
      hpos <= 0;
    else
      hpos <= hpos + 1;
  end

  // vertical position counter
  always @(posedge clk)
  begin
    vsync <= ~(vpos>=V_SYNC_START && vpos<=V_SYNC_END);
    if(hmaxxed)
      if (vmaxxed)
        vpos <= 0;
      else
        vpos <= vpos + 1;
  end

  // display_on is set when beam is in "safe" visible frame
  assign display_on = (hpos<H_DISPLAY) && (vpos<V_DISPLAY);

endmodule

`endif
