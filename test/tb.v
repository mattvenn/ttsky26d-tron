`default_nettype none
`timescale 1ns / 1ps

/* This testbench instantiates the module and makes some convenient wires
   that can be driven / tested by the cocotb test.py.

   It also captures frames to frame.ppm from the output pins alone, so it
   sees exactly what a Tiny VGA Pmod would, and works for gate level sims.
   Writing the file from Verilog means a whole frame passes in one cocotb
   await rather than ~660k Python callbacks.
*/
module tb ();

  initial begin
    if ($test$plusargs("fst")) begin
      $dumpfile("tb.fst");
      $dumpvars(0, tb);
    end
    #1;
  end

  // Wire up the inputs and outputs:
  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  tt_um_mattvenn_tron user_project (

      // Include power ports for the Gate Level test:
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif

      .ui_in  (ui_in),    // Dedicated inputs
      .uo_out (uo_out),   // Dedicated outputs
      .uio_in (uio_in),   // IOs: Input path
      .uio_out(uio_out),  // IOs: Output path
      .uio_oe (uio_oe),   // IOs: Enable path (active high: 0=input, 1=output)
      .ena    (ena),      // enable - goes high when design is selected
      .clk    (clk),      // clock
      .rst_n  (rst_n)     // not reset
  );

  // ---- frame capture from the pins
  wire hsync = uo_out[7];
  wire vsync = uo_out[3];
  wire [1:0] R = {uo_out[0], uo_out[4]};
  wire [1:0] G = {uo_out[1], uo_out[5]};
  wire [1:0] B = {uo_out[2], uo_out[6]};

  // 800x600@60: after hsync ends, 88 clocks of back porch, then 800 pixels.
  // After vsync ends, 23 lines of back porch, then 600 lines. Lines are
  // counted on the end of each hsync pulse. H_BP is one short because
  // spotting the end of hsync (hsync && !hsync_d) takes a clock itself.
  localparam H_BP = 87, V_BP = 23;

  reg        capture = 1'b0;  // set by cocotb; cleared when a frame is written
  reg        capturing = 1'b0;
  reg        hsync_d = 1'b1, vsync_d = 1'b1;
  integer    hcount = 0, lcount = 0, fd = 0;

  always @(posedge clk) begin
    hsync_d <= hsync;
    vsync_d <= vsync;

    if (hsync && !hsync_d) begin
      hcount <= 0;
      lcount <= lcount + 1;
    end else hcount <= hcount + 1;

    if (vsync && !vsync_d) begin
      lcount <= 0;
      if (capturing) begin
        $fclose(fd);
        capturing <= 1'b0;
        capture   <= 1'b0;
      end else if (capture) begin
        fd = $fopen("frame.ppm", "w");
        $fwrite(fd, "P3\n800 600\n3\n");
        capturing <= 1'b1;
      end
    end

    if (capturing && lcount >= V_BP && lcount < V_BP + 600 && hcount >= H_BP && hcount < H_BP + 800)
      $fwrite(fd, "%0d %0d %0d\n", R, G, B);
  end

endmodule
