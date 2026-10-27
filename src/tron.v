/*
 * Copyright (c) 2026 Matt Venn
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Four player Tron, raced against the beam on an 800x600 VGA screen.
//
// The playfield is a 50x37 grid of 16 px cells (37 rows = 592 lines; the last
// 8 lines are a score strip). Edges wrap on both axes. There is no
// framebuffer. Each trail is a list of corner points in one shared 64 entry
// ring in a register file (rf_top), and every cell's owner is worked out on
// the fly:
//
//   - A corner entry is {owner, sign, coordinate}: where the player turned,
//     stored as just the coordinate that changed (consecutive corners share
//     the other, and the axis alternates), and which way it left, plus or
//     minus. Each trail's first point is in a tail register. A trail is its
//     tail then the owner's entries in order, and its last segment runs from
//     the newest corner to the head, which lives in registers.
//   - Wraps need no entries. A straight segment can't wrap twice without
//     hitting its own start, so "from A, heading right, to B" covers
//     A..B even when B is left of A.
//   - When the ring is full the newest corner overwrites the oldest, and
//     that corner becomes its owner's tail: the oldest trail loses its first
//     segment instead of the game running out of memory.
//
// One query engine answers "who owns cell (x, y)?" by scanning the ring,
// one entry per clock, oldest to newest, then the four head segments: about
// 70 clocks. The renderer asks it 50 times per cell row, filling a line
// buffer for row r+1 while row r is on screen (16 lines = 16896 clocks
// available, ~3600 used). The game tick asks it once per player during
// vertical blank, which is all collision detection is.
module tron (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] speed,      // moves per second, see tick_period
    input  wire [3:0] btn_left_in,   // per player turn buttons, 1 = pressed
    input  wire [3:0] btn_right_in,
    input  wire       btn_start_in,  // any controller's start button
    input  wire [3:0] present_in,    // players that have a controller
    input  wire [1:0] input_mode,    // shown in the score strip: 1 Pmod, 2 Commander
    output wire       frame_tick,    // once a frame, for input_select's timeout
    output reg        hsync,
    output reg        vsync,
    output reg  [1:0] r,
    output reg  [1:0] g,
    output reg  [1:0] b
);

  localparam [5:0] GW = 6'd50;  // grid width in cells
  localparam [5:0] GH = 6'd37;  // grid height in cells

  localparam [1:0] DIR_RIGHT = 2'd0, DIR_DOWN = 2'd1, DIR_LEFT = 2'd2, DIR_UP = 2'd3;
  localparam [1:0] TURN_NONE = 2'd0, TURN_LEFT = 2'd1, TURN_RIGHT = 2'd2;

  localparam [1:0] R_READY = 2'd0, R_PLAY = 2'd1, R_OVER = 2'd2;

  localparam [3:0] G_IDLE = 4'd0, G_INIT = 4'd1, G_TURN = 4'd2, G_QUERY = 4'd3,
                   G_WAIT = 4'd4, G_DROP = 4'd5, G_MOVE = 4'd6, G_SCORE = 4'd7,
                   G_BOTP = 4'd8, G_BOTQ = 4'd9, G_BOTW = 4'd10, G_BOTD = 4'd11,
                   G_RMW1 = 4'd12, G_TURN2 = 4'd13, G_QPREP = 4'd14, G_RMW2 = 4'd15;

  // Controls are registered on the way in: the gamepad decoder's "is
  // anything plugged in" compare is otherwise in front of the turn queue.
  reg [3:0] btn_left, btn_right, present;
  reg       btn_start;
  always @(posedge clk) begin
    btn_left  <= btn_left_in;
    btn_right <= btn_right_in;
    btn_start <= btn_start_in;
    present   <= rst_n ? present_in : 4'b0;
  end

  integer i0, i1, i2, i3, j1;  // one loop variable per always block: yosys reads a shared one as several drivers
  integer ie;

  // ---------------------------------------------------------------- video

  wire [10:0] hpos;
  wire [9:0]  vpos;
  wire        display_on;
  wire        hsync_g, vsync_g;

  hvsync_generator sync (
      .clk       (clk),
      .reset     (~rst_n),
      .hsync     (hsync_g),
      .vsync     (vsync_g),
      .display_on(display_on),
      .hpos      (hpos),
      .vpos      (vpos)
  );

  // Schedule events fire just after the last visible pixel of a line and are
  // about the line after it, so a buffer swap lands before that line's first
  // pixel. Decoded a pixel early and registered, to keep the line counter's
  // compares off the paths they trigger.
  wire [9:0] nv = (vpos == 10'd627) ? 10'd0 : vpos + 10'd1;
  reg        ev_tick;    // vblank starts: game update
  reg        ev_row0;    // build row 0 before the frame
  reg        ev_swap;    // row ev_row goes on screen
  reg  [5:0] ev_row;
  always @(posedge clk) begin
    ev_tick <= (hpos == 11'd799) && (nv == 10'd600);
    ev_row0 <= (hpos == 11'd799) && (nv == 10'd612);
    ev_swap <= (hpos == 11'd799) && (nv[3:0] == 4'd0) && (nv < 10'd592);
    ev_row  <= nv[9:4];
  end

  assign frame_tick = ev_tick;

  // ---------------------------------------------------------- game state

  reg  [5:0] hx[0:3];
  reg  [5:0] hy[0:3];
  reg  [1:0] hd[0:3];
  reg  [3:0] alive;
  reg  [3:0] score[0:3];   // rounds won, up to 12
  // Someone has won 12: every pip flashes for this many frames, then all
  // the scores go back to 0. The next round waits for it.
  localparam [6:0] MATCH_FRAMES = 7'd127;  // about 2 s
  reg  [6:0] match_end;

  reg  [1:0] round;
  // Before the last move. If it leaves nobody alive the round is a draw:
  // those who died in it come back, so their trails stay on screen.
  reg  [3:0] alive_was;
  reg  [3:0] frame_cnt;

  // Memory: one 32 word x 32 bit register file (Sylvain Munaut's rf_top
  // macro: one write port, two read ports, reads registered).
  //   words 0-21   the trail ring, 3 corners of 9 bits a word: 66 corners
  //   words 22-31  two line buffers, 5 words of 10 cells of 3 bits each
  localparam [4:0] TW   = 5'd22;   // trail words
  localparam [6:0] RING = 7'd66;   // corners
  localparam [4:0] LB_A = 5'd22, LB_B = 5'd27;

  reg  [4:0]  o_w, n_w;   // oldest corner, and the next slot to write: word
  reg  [1:0]  o_l, n_l;   // and lane in the word
  reg  [6:0]  count;      // corners in the ring, saturates at RING

  reg         rf_we;
  reg  [4:0]  rf_waddr;
  reg  [31:0] rf_wdata;
  wire [4:0]  rf_ra_addr, rf_rb_addr;
  wire [31:0] rf_ra, rf_rb;

  rf_top rf (
      .w_data (rf_wdata),
      .w_addr (rf_waddr),
      .w_ena  (rf_we),
      .ra_addr(rf_ra_addr),
      .rb_addr(rf_rb_addr),
      .ra_data(rf_ra),
      .rb_data(rf_rb),
      .clk    (clk)
  );

  function [8:0] lane;
    input [26:0] w;
    input [1:0]  l;
    lane = (l == 2'd0) ? w[8:0] : (l == 2'd1) ? w[17:9] : w[26:18];
  endfunction

  wire _unused_rf = &{rf_ra[31:30], rf_rb[31:27], 1'b0};  // words use 30 and 27 bits

  // ---------------------------------------------------------- query engine
  //
  // Is cell q on the segment that leaves corner a along an axis, plus or
  // minus, and ends at b? Along the axis, the distance from a to q must be
  // no more than from a to b, both taken modulo the grid so wrapped segments
  // work. Pipelined over five stages to make 40 MHz on the iCE40:
  //
  //   R   the word arrives from the register file; register the corner
  //   S0  pick a, b and the owner, for a corner or a head
  //   S1  on_line, and the two raw distances u (a to q) and v (a to b)
  //   S2  wrap u and v into the grid
  //   S3  compare; record a hit
  //
  // A corner is stored as only the coordinate that changed: consecutive
  // corners of a trail share the other one, and the axis alternates. Each
  // trail's first point, and the axis and sign it leaves on, lives in a
  // tail register; walking a trail starts there and fills in each corner
  // from the one before. A drum entry is {owner, sign, coordinate}.

  reg        e_start;
  reg  [5:0] e_sx, e_sy;  // cell to ask about, sampled on e_start

  reg        e_run;
  reg  [6:0] e_s;         // next item: entries 0..count-1, then heads 0..3
  reg  [4:0] e_w;         // the corner being read: word
  reg  [1:0] e_l, e_rl;   // and lane, as issued and as its word arrives (R)
  reg  [5:0] e_qx, e_qy;
  reg        e_rv, e_rhead, e_rlast;  // R: the item whose word arrives this cycle
  reg  [1:0] e_rp;
  reg        e_pv, e_phead, e_plast;  // S0: the item being used this cycle
  reg  [1:0] e_pp;
  reg  [8:0] ent;                     // S0: the corner, registered in R
  reg        e_done, e_hit;
  reg  [1:0] e_owner;
  // Each player's latest corner so far, starting from its tail:
  // {vertical, sign, x, y} for the segment that leaves it.
  reg [13:0] prev[0:3];
  reg [13:0] tail[0:3];   // written by the game tick: new round, dropped corners

  wire [6:0] e_hidx_full = e_s - count;
  wire [1:0] e_hidx = e_hidx_full[1:0];
  wire _unused_hidx = &{e_hidx_full[6:2], 1'b0};

  // S0 operands. A stored corner closes the segment from its owner's
  // previous corner; a head closes the live segment from the newest one.
  wire [8:0]  ent_in = lane(rf_rb[26:0], e_rl);  // outside the clocked block, for yosys
  wire [1:0]  eo    = ent[8:7];
  wire [13:0] eprev = prev[eo];
  // The corner itself: the previous one with the coordinate along its axis replaced.
  wire [5:0]  e_bx  = eprev[13] ? eprev[11:6] : ent[5:0];
  wire [5:0]  e_by  = eprev[13] ? ent[5:0] : eprev[5:0];
  wire [13:0] s0_a  = e_phead ? prev[e_pp] : eprev;
  wire [5:0]  s0_bx = e_phead ? hx[e_pp] : e_bx;
  wire [5:0]  s0_by = e_phead ? hy[e_pp] : e_by;
  wire [1:0]  s0_o  = e_phead ? e_pp : eo;
  wire        s0_v  = e_pv && alive[s0_o];

  reg        s1_v, s1_last, s1_horiz, s1_sign;
  reg  [1:0] s1_o;
  reg  [5:0] s1_ax, s1_ay, s1_bx, s1_by;

  // S1: distances along the segment's axis, negated for left and up.
  wire [5:0] s1_p0 = s1_horiz ? s1_ax : s1_ay;
  wire [5:0] s1_p1 = s1_horiz ? e_qx : e_qy;
  wire [5:0] s1_e  = s1_horiz ? s1_bx : s1_by;
  wire [6:0] s1_u  = s1_sign ? {1'b0, s1_p0} - {1'b0, s1_p1} : {1'b0, s1_p1} - {1'b0, s1_p0};
  wire [6:0] s1_w  = s1_sign ? {1'b0, s1_p0} - {1'b0, s1_e} : {1'b0, s1_e} - {1'b0, s1_p0};
  wire       s1_on = s1_horiz ? (e_qy == s1_ay) : (e_qx == s1_ax);

  reg        s2_v, s2_last, s2_horiz;
  reg  [1:0] s2_o;
  reg  [6:0] s2_u, s2_w;

  // S2: a negative distance wrapped around the grid edge.
  wire [6:0] s2_m  = s2_horiz ? {1'b0, GW} : {1'b0, GH};
  wire [6:0] s2_um = s2_u[6] ? s2_u + s2_m : s2_u;
  wire [6:0] s2_wm = s2_w[6] ? s2_w + s2_m : s2_w;

  reg        s3_v, s3_last;
  reg  [1:0] s3_o;
  reg  [6:0] s3_um, s3_wm;

  // Set by the game tick (G_TURN2): point the idle engine's read port at
  // word n_w.
  reg        rmw_req;

  always @(posedge clk) begin
    e_done <= 1'b0;
    if (!rst_n) begin
      e_run   <= 1'b0;
      e_pv    <= 1'b0;
      e_rv    <= 1'b0;
      e_hit   <= 1'b0;
      s1_v    <= 1'b0;
      s1_last <= 1'b0;
      s2_v    <= 1'b0;
      s2_last <= 1'b0;
      s3_v    <= 1'b0;
      s3_last <= 1'b0;
    end else if (e_start) begin
      e_run   <= 1'b1;
      e_s     <= 7'd0;
      e_w     <= o_w;
      e_l     <= o_l;
      e_qx    <= e_sx;
      e_qy    <= e_sy;
      e_pv    <= 1'b0;
      e_rv    <= 1'b0;
      e_hit   <= 1'b0;
      for (ie = 0; ie < 4; ie = ie + 1) prev[ie] <= tail[ie];
      s1_v    <= 1'b0;
      s1_last <= 1'b0;
      s2_v    <= 1'b0;
      s2_last <= 1'b0;
      s3_v    <= 1'b0;
      s3_last <= 1'b0;
    end else begin
      // Issue: rf_rb_addr is e_w; the word arrives a clock later, in S0.
      if (rmw_req) e_w <= n_w;  // engine idle: the game tick reads a word
      e_rv <= e_run;
      if (e_run) begin
        e_rl <= e_l;
        if (e_l == 2'd2) begin
          e_l <= 2'd0;
          e_w <= (e_w == TW - 5'd1) ? 5'd0 : e_w + 5'd1;
        end else e_l <= e_l + 2'd1;
        e_rhead <= (e_s >= count);
        e_rp    <= e_hidx;
        e_rlast <= (e_s == count + 7'd3);
        e_s     <= e_s + 7'd1;
        if (e_s == count + 7'd3) e_run <= 1'b0;
      end

      // R
      e_pv    <= e_rv;
      e_phead <= e_rhead;
      e_pp    <= e_rp;
      e_plast <= e_rlast;
      ent     <= ent_in;

      // S0
      s1_v     <= s0_v;
      s1_last  <= e_pv && e_plast;
      s1_horiz <= ~s0_a[13];
      s1_sign  <= s0_a[12];
      s1_ax    <= s0_a[11:6];
      s1_ay    <= s0_a[5:0];
      s1_bx    <= s0_bx;
      s1_by    <= s0_by;
      s1_o     <= s0_o;
      if (e_pv && !e_phead) prev[eo] <= {~eprev[13], ent[6], e_bx, e_by};

      // S1
      s2_v     <= s1_v && s1_on;
      s2_last  <= s1_last;
      s2_horiz <= s1_horiz;
      s2_o     <= s1_o;
      s2_u     <= s1_u;
      s2_w     <= s1_w;

      // S2
      s3_v    <= s2_v;
      s3_last <= s2_last;
      s3_o    <= s2_o;
      s3_um   <= s2_um;
      s3_wm   <= s2_wm;

      // S3
      if (s3_v && s3_um <= s3_wm) begin
        e_hit   <= 1'b1;
        e_owner <= s3_o;
      end
      if (s3_last) e_done <= 1'b1;
    end
  end

  // ---------------------------------------------------------- line buffers

  // Two rows of 50 cells, 3 bits each: {occupied, owner}, both shift
  // registers. The builder works out the next cell row's cells left to
  // right and shifts each into the back buffer; the front buffer is shown,
  // its first cell rotating out every 16 pixels, 50 times a line, so it is
  // back at the start for the next line. When a new cell row starts the
  // back buffer is copied to the front. Shifting rather than addressing
  // keeps every wire local: an addressed pair needed a 50-way read mux and
  // write decode, and the ASIC router could not fit them in 3x2.
  reg          front;     // which register file line buffer is on screen: 0 LB_A
  reg  [26:0]  bacc;      // the builder's cells so far for the next word
  reg  [3:0]   bcnt;      // ... how many
  reg  [2:0]   bgroup;    // ... and which word of the back buffer
  wire         lb_write;  // the builder has a cell for the back buffer
  reg          building;
  reg  [5:0]   brow, bcol;
  reg          b_start;  // builder wants the engine next cycle

  // ------------------------------------------------------------ game tick

  reg  [3:0] gstate;
  reg  [3:0] gret;        // where G_RMW2 goes once the corner is written
  reg  [8:0] t_ent;       // the corner G_RMW1/2 adds to the ring
  reg        rmw_ph;
  // Adding a corner reads its word (G_RMW1), puts it in its lane and writes
  // the word back (G_RMW2). When the ring is full that lane held the oldest
  // corner, which becomes its owner's tail.
  reg  [26:0] rmw_word;   // the word read, registered before it's used
  wire [8:0]  old    = lane(rmw_word, n_l);
  wire [26:0] merged = (n_l == 2'd0) ? {rmw_word[26:9], t_ent} :
                       (n_l == 2'd1) ? {rmw_word[26:18], t_ent, rmw_word[8:0]} :
                                       {t_ent, rmw_word[17:0]};
  reg  [8:0]  old_r;      // the corner overwritten, for G_DROP
  reg         full_r;
  wire [1:0]  drop_o = old_r[8:7];
  wire [13:0] drop_t = tail[drop_o];
  wire [13:0] drop_tail = {~drop_t[13], old_r[6],
                           drop_t[13] ? drop_t[11:6] : old_r[5:0],
                           drop_t[13] ? old_r[5:0] : drop_t[5:0]};
  wire _unused_drop = drop_t[12];  // the old tail's sign: its segment is gone
  reg        t_do;        // G_TURN to G_TURN2: this player turns,
  reg  [1:0] t_dir;       // to this direction,
  reg  [5:0] t_x, t_y;    // at this corner
  reg  [1:0] gp;          // player being processed
  reg  [3:0] kill;
  reg        need_init;
  reg  [1:0] init_round;  // round state to enter after G_INIT
  reg        start_pending;
  reg  [2:0] tdiv;

  reg  [3:0] btn_left_d, btn_right_d;
  reg        btn_start_d;
  reg  [1:0] tq0[0:3];    // two deep queue of turns per player
  reg  [1:0] tq1[0:3];

  // A player joins (becomes human) when one of its turn buttons is pressed on
  // a plugged in controller, and stays human until the game goes back to
  // attract mode. Until then it is a bot, like the browser demo's: straight
  // on, turning into a free cell when blocked, and now and then at random.
  //
  // Attract mode: after IDLE_FRAMES with no button pressed outside a round,
  // everyone becomes a bot and rounds start by themselves. Any button ends
  // it, back to the start positions (the lobby): joined players' heads show
  // solid white, the rest blink, and Start begins the round.

  reg  [3:0] human;
  wire [3:0] is_bot = ~(human & present);
  reg  [1:0] bstep;       // bot looking: 0 straight, 1 left, 2 right
  reg        bfree_l;
  reg        bhit;        // the engine's answer, registered for G_BOTD
  reg        brand;       // a random turn this move
  reg        bpick;       // left (1) or right (0) when both are free
  localparam [10:0] IDLE_FRAMES = 11'd1800;  // 30 s
  reg [10:0] idle;        // frames since a button was pressed
  reg        pressed;     // a button was pressed since the last frame
  reg  [5:0] auto_wait;   // frames between attract rounds
  reg        attract;     // in attract mode
  reg        abort;       // a button was pressed in attract mode
  reg [15:0] lfsr;
  always @(posedge clk)
    if (!rst_n) lfsr <= 16'hACE1;
    else lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

  // The cell one step from (x, y) in direction d, with wrap: {x, y}
  function [11:0] step;
    input [5:0] x, y;
    input [1:0] d;
    case (d)
      DIR_RIGHT: step = {(x == GW - 6'd1) ? 6'd0 : x + 6'd1, y};
      DIR_LEFT:  step = {(x == 6'd0) ? GW - 6'd1 : x - 6'd1, y};
      DIR_DOWN:  step = {x, (y == GH - 6'd1) ? 6'd0 : y + 6'd1};
      DIR_UP:    step = {x, (y == 6'd0) ? GH - 6'd1 : y - 6'd1};
    endcase
  endfunction

  wire [1:0]  bot_dir = hd[gp] + ((bstep == 2'd1) ? 2'd3 : (bstep == 2'd2) ? 2'd1 : 2'd0);
  // Registered in G_BOTP, the cycle before G_BOTQ uses it.
  reg  [11:0] bot_cell;
  always @(posedge clk) bot_cell <= step(hx[gp], hy[gp], bot_dir);

  // 60 frames per second divided by this many frames per move.
  reg  [2:0] tick_period;
  always @(*) begin
    case (speed)
      2'd0: tick_period = 3'd6;  // 10 moves/s
      2'd1: tick_period = 3'd4;  // 15 moves/s
      2'd2: tick_period = 3'd7;  // 8.6 moves/s
      2'd3: tick_period = 3'd1;  // 60 moves/s, for simulation
    endcase
  end

  // Where each head moves next, with wrap. Only player gp's is registered
  // (tx_gp, ty_gp, in G_QPREP for G_QUERY); the head-on check and the move
  // use these directly, each in a state of its own.
  reg [5:0] tx[0:3];
  reg [5:0] ty[0:3];
  reg  [5:0] tx_gp, ty_gp;
  always @(*) begin
    for (i0 = 0; i0 < 4; i0 = i0 + 1) begin
      tx[i0] = hx[i0];
      ty[i0] = hy[i0];
      case (hd[i0])
        DIR_RIGHT: tx[i0] = (hx[i0] == GW - 6'd1) ? 6'd0 : hx[i0] + 6'd1;
        DIR_LEFT:  tx[i0] = (hx[i0] == 6'd0) ? GW - 6'd1 : hx[i0] - 6'd1;
        DIR_DOWN:  ty[i0] = (hy[i0] == GH - 6'd1) ? 6'd0 : hy[i0] + 6'd1;
        DIR_UP:    ty[i0] = (hy[i0] == 6'd0) ? GH - 6'd1 : hy[i0] - 6'd1;
      endcase
    end
  end

  // Also registered, for G_QUERY and G_BOTQ (G_QPREP and G_BOTP give them
  // the cycle): is player gp alive, and a bot.
  reg gp_alive, gp_bot;
  always @(posedge clk) begin
    tx_gp    <= tx[gp];
    ty_gp    <= ty[gp];
    gp_alive <= alive[gp];
    gp_bot   <= alive[gp] && is_bot[gp];
  end

  // Two heads moving into the same cell both die. Rather than compare where
  // they're going, let them go and then look for two heads in one cell:
  // registered positions only, no arithmetic in front of the compare.
  reg [3:0] shared, shared_r;
  always @(posedge clk) shared_r <= shared;
  always @(*) begin
    for (i1 = 0; i1 < 4; i1 = i1 + 1) begin
      shared[i1] = 1'b0;
      for (j1 = 0; j1 < 4; j1 = j1 + 1)
        if (i1 != j1 && alive[i1] && alive[j1] && hx[i1] == hx[j1] && hy[i1] == hy[j1])
          shared[i1] = 1'b1;
    end
  end

  // Counted from alive and registered; G_SCORE waits a cycle after G_MOVE
  // updates alive so these have caught up.
  reg  [2:0] n_alive;
  reg  [1:0] alive_idx;
  always @(posedge clk) begin
    n_alive   <= {2'b0, alive[0]} + {2'b0, alive[1]} + {2'b0, alive[2]} + {2'b0, alive[3]};
    alive_idx <= alive[0] ? 2'd0 : alive[1] ? 2'd1 : alive[2] ? 2'd2 : 2'd3;
  end

  // Start positions: the four quarter points, all heading clockwise.
  function [13:0] start_pos;  // {dir, x, y}
    input [1:0] p;
    case (p)
      2'd0: start_pos = {DIR_RIGHT, 6'd12, 6'd9};
      2'd1: start_pos = {DIR_DOWN,  6'd37, 6'd9};
      2'd2: start_pos = {DIR_LEFT,  6'd37, 6'd27};
      2'd3: start_pos = {DIR_UP,    6'd12, 6'd27};
    endcase
  endfunction

  wire [13:0] sp = start_pos(gp);
  wire [1:0]  turned = (tq0[gp] == TURN_LEFT) ? hd[gp] - 2'd1 : hd[gp] + 2'd1;
  wire [3:0]  btn_left_rise = btn_left & ~btn_left_d;
  wire [3:0]  btn_right_rise = btn_right & ~btn_right_d;
  wire        any_press = (btn_start && !btn_start_d) ||
                          |(present & (btn_left_rise | btn_right_rise));

  always @(posedge clk) begin
    e_start <= 1'b0;
    b_start <= 1'b0;
    rf_we   <= 1'b0;
    rmw_req <= 1'b0;

    if (!rst_n) begin
      gstate        <= G_IDLE;
      rf_we         <= 1'b0;
      front         <= 1'b0;
      round         <= R_READY;
      need_init     <= 1'b1;
      start_pending <= 1'b0;
      alive         <= 4'b0;
      kill          <= 4'b0;
      frame_cnt     <= 4'd0;
      match_end     <= 7'd0;
      tdiv          <= 3'd0;
      count         <= 7'd0;
      building      <= 1'b0;
      btn_left_d    <= 4'b0;
      btn_right_d   <= 4'b0;
      human         <= 4'b0;
      auto_wait     <= 6'd0;
      attract       <= 1'b0;
      abort         <= 1'b0;
      pressed       <= 1'b0;
      idle          <= IDLE_FRAMES - 11'd60;  // attract mode a second after reset
      bstep         <= 2'd0;
      btn_start_d   <= 1'b0;
      for (i2 = 0; i2 < 4; i2 = i2 + 1) begin
        score[i2] <= 4'd0;
        tq0[i2]   <= TURN_NONE;
        tq1[i2]   <= TURN_NONE;
        hx[i2]    <= 6'd0;
        hy[i2]    <= 6'd0;
        hd[i2]    <= 2'd0;
      end
    end else begin

      // ---- controls
      btn_left_d  <= btn_left;
      btn_right_d <= btn_right;
      btn_start_d <= btn_start;
      if (any_press) pressed <= 1'b1;
      if (btn_start && !btn_start_d && round != R_PLAY && !attract) start_pending <= 1'b1;
      if (attract && any_press) abort <= 1'b1;
      human <= human | (present & (btn_left | btn_right));

      // Queue turns during play; G_TURN pops one per player per move.
      for (i2 = 0; i2 < 4; i2 = i2 + 1) begin
        if (round != R_PLAY) begin
          tq0[i2] <= TURN_NONE;
          tq1[i2] <= TURN_NONE;
        end else if (btn_left_rise[i2] || btn_right_rise[i2]) begin
          if (tq0[i2] == TURN_NONE) tq0[i2] <= btn_left_rise[i2] ? TURN_LEFT : TURN_RIGHT;
          else if (tq1[i2] == TURN_NONE) tq1[i2] <= btn_left_rise[i2] ? TURN_LEFT : TURN_RIGHT;
        end
      end

      // ---- game tick sequencer
      case (gstate)
        G_IDLE: if (ev_tick) begin
          frame_cnt <= frame_cnt + 4'd1;
          pressed <= 1'b0;
          if (match_end != 7'd0) begin
            match_end <= match_end - 7'd1;
            if (match_end == 7'd1)
              for (i2 = 0; i2 < 4; i2 = i2 + 1) score[i2] <= 4'd0;
          end
          if (pressed || any_press) idle <= 11'd0;
          else if (idle != 11'h7ff) idle <= idle + 11'd1;
          // Attract rounds follow each other a second apart.
          if (attract && round == R_OVER) begin
            auto_wait <= auto_wait + 6'd1;
            if (auto_wait == 6'd63) start_pending <= 1'b1;
          end else auto_wait <= 6'd0;
          // Nobody about: everyone becomes a bot and attract mode starts.
          if (!attract && round != R_PLAY && idle >= IDLE_FRAMES) begin
            attract       <= 1'b1;
            human         <= 4'b0;
            start_pending <= 1'b1;
          end
          if (need_init || abort) begin
            gstate        <= G_INIT;
            gp            <= 2'd0;
            init_round    <= R_READY;
            abort         <= 1'b0;
            attract       <= 1'b0;
            start_pending <= 1'b0;
            auto_wait     <= 6'd0;
          end else if (start_pending && round == R_READY) begin
            round         <= R_PLAY;
            start_pending <= 1'b0;
            tdiv          <= tick_period - 3'd1;
          end else if (start_pending && round == R_OVER && match_end == 7'd0) begin
            gstate        <= G_INIT;
            gp            <= 2'd0;
            init_round    <= R_PLAY;
            start_pending <= 1'b0;
          end else if (round == R_PLAY) begin
            if (tdiv == 3'd0) begin
              tdiv   <= tick_period - 3'd1;
              gstate <= G_BOTP;
              gp     <= 2'd0;
              bstep  <= 2'd0;
            end else begin
              tdiv <= tdiv - 3'd1;
            end
          end
        end

        // New round: every player back to its start corner.
        G_INIT: begin
          for (i2 = 0; i2 < 4; i2 = i2 + 1) if (gp == i2[1:0]) alive[i2] <= 1'b1;
          hd[gp]    <= sp[13:12];
          hx[gp]    <= sp[11:6];
          hy[gp]    <= sp[5:0];
          // The start point is the trail's tail; the drum is empty.
          tail[gp]  <= {sp[12], sp[13], sp[11:0]};
          count     <= 7'd0;
          o_w       <= 5'd0;
          o_l       <= 2'd0;
          n_w       <= 5'd0;
          n_l       <= 2'd0;
          gp        <= gp + 2'd1;
          if (gp == 2'd3) begin
            gstate     <= G_IDLE;
            round      <= init_round;
            need_init  <= 1'b0;
            tdiv       <= tick_period - 3'd1;
          end
          kill <= 4'b0;
        end

        // Bots choose their turn by asking the query engine about the cells
        // ahead, then left and right, and queue it like a button press.
        G_BOTP: gstate <= G_BOTQ;

        G_BOTQ: begin
          if (gp_bot) begin
            e_start <= 1'b1;
            e_sx    <= bot_cell[11:6];
            e_sy    <= bot_cell[5:0];
            gstate  <= G_BOTW;
          end else begin
            gp     <= gp + 2'd1;
            gstate <= (gp == 2'd3) ? G_TURN : G_BOTP;
          end
        end

        G_BOTW: if (e_done) begin
          bhit   <= e_hit;
          brand  <= (lfsr[4:0] == 5'd0);
          bpick  <= lfsr[5];
          gstate <= G_BOTD;
        end

        G_BOTD: begin
          if (bstep == 2'd0 && !bhit && !brand) begin
            // ahead is clear and no random turn (31 times in 32): carry on
            gp     <= gp + 2'd1;
            gstate <= (gp == 2'd3) ? G_TURN : G_BOTP;
          end else if (bstep != 2'd2) begin
            if (bstep == 2'd1) bfree_l <= !bhit;
            bstep  <= bstep + 2'd1;
            gstate <= G_BOTP;
          end else begin
            // Turn to a free side, a random one if both are; if neither is,
            // carry on and crash.
            if (bfree_l && !bhit) tq0[gp] <= bpick ? TURN_LEFT : TURN_RIGHT;
            else if (bfree_l) tq0[gp] <= TURN_LEFT;
            else if (!bhit) tq0[gp] <= TURN_RIGHT;
            bstep  <= 2'd0;
            gp     <= gp + 2'd1;
            gstate <= (gp == 2'd3) ? G_TURN : G_BOTP;
          end
        end

        // Apply one queued turn per player, storing the corner. Looked up
        // in G_TURN and applied in G_TURN2, for timing.
        G_TURN: begin
          t_do   <= alive[gp] && tq0[gp] != TURN_NONE;
          t_dir  <= turned;
          t_x    <= hx[gp];
          t_y    <= hy[gp];
          gstate <= G_TURN2;
        end

        G_TURN2: begin
          if (t_do) begin
            hd[gp]    <= t_dir;
            // Store the coordinate that changed: x if the trail arrived
            // moving horizontally, which it did if it now leaves vertically.
            t_ent     <= {gp, t_dir[1], t_dir[0] ? t_x : t_y};
            rmw_req   <= 1'b1;
            rmw_ph    <= 1'b0;
            gstate    <= G_RMW1;
            gret      <= (gp == 2'd3) ? G_QPREP : G_TURN;
          end else gstate <= (gp == 2'd3) ? G_QPREP : G_TURN;
          tq0[gp] <= tq1[gp];
          tq1[gp] <= TURN_NONE;
          gp      <= gp + 2'd1;
        end

        // Is the cell each live head is about to enter already taken?
        // G_QPREP gives tx_gp a cycle to catch up with gp.
        G_QPREP: gstate <= G_QUERY;

        G_QUERY: begin
          if (gp_alive) begin
            e_start <= 1'b1;
            e_sx    <= tx_gp;
            e_sy    <= ty_gp;
            gstate  <= G_WAIT;
          end else begin
            gp     <= gp + 2'd1;
            gstate <= (gp == 2'd3) ? G_MOVE : G_QPREP;
          end
        end

        G_WAIT: if (e_done) begin
          for (i2 = 0; i2 < 4; i2 = i2 + 1) if (e_hit && gp == i2[1:0]) kill[i2] <= 1'b1;
          gp     <= gp + 2'd1;
          gstate <= (gp == 2'd3) ? G_MOVE : G_QPREP;
        end

        G_MOVE: begin
          for (i2 = 0; i2 < 4; i2 = i2 + 1)
            if (alive[i2] && !kill[i2]) begin
              hx[i2] <= tx[i2];
              hy[i2] <= ty[i2];
            end
          alive_was <= alive;
          alive  <= alive & ~kill;
          kill   <= 4'b0;  // ready for the next move
          gstate <= G_SCORE;
          gp     <= 2'd0;
        end

        // gp counts the steps: 0 shared_r catches up with the move, 1 heads
        // that met die, 2 n_alive catches up, 3 the result.
        G_SCORE: if (gp == 2'd0) begin
          gp <= 2'd1;
        end else if (gp == 2'd1) begin
          alive <= alive & ~shared_r;
          gp    <= 2'd2;
        end else if (gp == 2'd2) begin
          gp <= 2'd3;
        end else begin
          if (n_alive <= 3'd1) begin
            round      <= R_OVER;
            if (n_alive == 3'd0) alive <= alive_was;  // a draw
            if (n_alive == 3'd1 && score[alive_idx] != 4'd12)
              score[alive_idx] <= score[alive_idx] + 4'd1;
            if (n_alive == 3'd1 && score[alive_idx] == 4'd11)
              match_end <= MATCH_FRAMES;
          end
          gstate <= G_IDLE;
        end

        // A clock for e_w to load n_w, then one for the read.
        G_RMW1: begin
          rmw_ph <= ~rmw_ph;
          if (rmw_ph) gstate <= G_RMW2;
        end

        G_RMW2: if (!rmw_ph) begin
          rmw_word <= rf_rb[26:0];
          rmw_ph   <= 1'b1;
        end else begin
          rf_we    <= 1'b1;
          rf_waddr <= n_w;
          rf_wdata <= {5'b0, merged};
          old_r    <= old;
          full_r   <= (count == RING);
          if (count == RING) begin
            o_w <= n_w;  // full: the oldest is the next one along
            o_l <= n_l;
            if (n_l == 2'd2) begin
              o_l <= 2'd0;
              o_w <= (n_w == TW - 5'd1) ? 5'd0 : n_w + 5'd1;
            end else o_l <= n_l + 2'd1;
          end else count <= count + 7'd1;
          if (n_l == 2'd2) begin
            n_l <= 2'd0;
            n_w <= (n_w == TW - 5'd1) ? 5'd0 : n_w + 5'd1;
          end else n_l <= n_l + 2'd1;
          gstate <= G_DROP;
        end

        // Full ring: the overwritten corner becomes its owner's tail.
        G_DROP: begin
          if (full_r) tail[drop_o] <= drop_tail;
          gstate <= gret;
        end

        default: gstate <= G_IDLE;
      endcase

      // ---- row builder: work out the next row a cell at a time, writing
      // each 10 cells to the back line buffer as a word
      if (ev_row0 || ev_swap) begin
        if (ev_swap) front <= ~front;
        // Row ev_row is going on screen, so build the one after it.
        if (ev_row0 || ev_row != GH - 6'd1) begin
          building <= 1'b1;
          brow     <= ev_row0 ? 6'd0 : ev_row + 6'd1;
          bcol     <= 6'd0;
          bcnt     <= 4'd0;
          bgroup   <= 3'd0;
          b_start  <= 1'b1;
        end
      end else if (lb_write) begin
        if (bcnt == 4'd9) begin
          // The game tick's writes are all in vertical blank, done before
          // row 0 is built, so the write port is free.
          rf_we    <= 1'b1;
          rf_waddr <= (front ? LB_A : LB_B) + {2'b00, bgroup};
          rf_wdata <= {2'b00, bacc, e_hit, e_owner};
          bcnt     <= 4'd0;
          bgroup   <= bgroup + 3'd1;
        end else begin
          bacc <= {bacc[23:0], e_hit, e_owner};
          bcnt <= bcnt + 4'd1;
        end
        if (bcol == GW - 6'd1) building <= 1'b0;
        else begin
          bcol    <= bcol + 6'd1;
          b_start <= 1'b1;
        end
      end
      if (b_start) begin
        e_start <= 1'b1;
        e_sx    <= bcol;
        e_sy    <= brow;
      end
    end
  end

  // ---------------------------------------------------------------- pixels

  wire [5:0] cx = hpos[9:4];
  wire [5:0] cy = vpos[9:4];
  assign lb_write = building && e_done && !ev_row0 && !ev_swap;

  // The front line buffer is read a word (10 cells) at a time on read port
  // A into disp, which moves on a cell every 16 pixels. The next word is
  // always on port A's output by the time it's needed: dnext is the group
  // after the one showing, or the first during horizontal blank.
  reg  [29:0] disp;
  reg  [2:0]  dgroup;
  reg  [3:0]  dcell;
  reg         lb_rot;     // last pixel of a cell next
  reg         lb_line;    // first pixel of a line next
  wire [2:0]  dnext = (hpos >= 11'd800) ? 3'd0 : dgroup + 3'd1;
  assign rf_ra_addr = (front ? LB_B : LB_A) + {2'b00, dnext};
  assign rf_rb_addr = e_w;  // the read-modify-write borrows it via rmw_req

  always @(posedge clk) begin
    lb_rot  <= (hpos[3:0] == 4'd14) && (hpos < 11'd800);
    lb_line <= (hpos == 11'd1054);
    if (lb_line) begin
      disp   <= rf_ra[29:0];
      dgroup <= 3'd0;
      dcell  <= 4'd0;
    end else if (lb_rot) begin
      if (dcell == 4'd9) begin
        disp   <= rf_ra[29:0];
        dgroup <= dgroup + 3'd1;
        dcell  <= 4'd0;
      end else begin
        disp  <= {disp[26:0], 3'b000};
        dcell <= dcell + 4'd1;
      end
    end
  end

  wire [2:0] lbcell = disp[29:27];  // cell hpos / 16

  reg is_head, head_joined;
  always @(*) begin
    is_head = 1'b0;
    head_joined = 1'b0;
    for (i3 = 0; i3 < 4; i3 = i3 + 1)
      if (alive[i3] && hx[i3] == cx && hy[i3] == cy) begin
        is_head = 1'b1;
        head_joined = human[i3] & present[i3];
      end
  end

  // RGB222 colours, as {r, g, b}
  function [5:0] pcol;
    input [1:0] p;
    case (p)
      2'd0: pcol = 6'b00_11_11;  // cyan
      2'd1: pcol = 6'b11_10_00;  // orange
      2'd2: pcol = 6'b11_00_11;  // magenta
      2'd3: pcol = 6'b10_11_00;  // lime
    endcase
  endfunction

  localparam [5:0] WHITE = 6'b11_11_11, GRID = 6'b00_00_01, BLACK = 6'b00_00_00;

  // Score strip: a quarter of the width per player, up to 12 pips of 16 px.
  wire [1:0]  sp_p = (hpos < 11'd200) ? 2'd0 : (hpos < 11'd400) ? 2'd1 :
                     (hpos < 11'd600) ? 2'd2 : 2'd3;
  wire [10:0] sp_x = hpos - {sp_p, 3'b000} * 11'd25;  // hpos - 200 * sp_p
  // Registered a pixel early (so the pips sit 1 px right) to keep the
  // subtract and the score compare in separate cycles.
  reg  [1:0]  sp_p_r;
  reg  [7:0]  sp_x_r;
  reg         sp_on;
  always @(posedge clk) begin
    sp_p_r <= sp_p;
    sp_x_r <= sp_x[7:0];
    sp_on  <= (vpos >= 10'd594) && (vpos < 10'd598) && (sp_x < 11'd192);
  end
  // While a match ends every pip lights, flashing.
  wire        pip = sp_on && (sp_x_r[3:0] >= 4'd2) && (sp_x_r[3:0] < 4'd14) &&
                    (match_end != 7'd0 ? frame_cnt[2] : sp_x_r[7:4] < score[sp_p_r]);

  // Bottom right corner, past the last player's pips: which controls are in
  // use. White for the Gamepad Pmod, blue for the Commander, nothing while
  // deciding.
  reg mode_mark;
  always @(posedge clk)
    mode_mark <= (vpos >= 10'd594) && (vpos < 10'd598) && (hpos >= 11'd792) && (hpos < 11'd800);

  // Two pixel stages: the lookups (line buffer, heads, pips) are registered,
  // then the colour is chosen and registered. The generator's syncs are
  // already one register behind hpos, so they get one more to match.
  reg       px_on, px_strip, px_pip, px_mark, px_head, px_joined, px_grid;
  reg [1:0] px_p;
  reg [2:0] px_cell;
  always @(posedge clk) begin
    px_on    <= display_on;
    px_strip <= (vpos >= 10'd592);
    px_pip   <= pip;
    px_mark  <= mode_mark;
    px_p     <= sp_p_r;
    px_head  <= is_head;
    px_joined <= head_joined;
    px_cell  <= lbcell;
    px_grid  <= (hpos[3:0] == 4'd0 || vpos[3:0] == 4'd0);
    hsync    <= hsync_g;
    vsync    <= vsync_g;
  end

  reg [5:0] rgb;
  always @(*) begin
    if (!px_on) rgb = BLACK;
    else if (px_strip) rgb = px_pip ? pcol(px_p) :
                             !px_mark ? BLACK :
                             input_mode[0] ? WHITE : input_mode[1] ? 6'b00_01_11 : BLACK;
    else if (px_head) rgb = (round == R_READY && !px_joined && frame_cnt[3]) ? pcol(px_cell[1:0]) : WHITE;
    // Once a round is over only the winner's trail is left, or in a draw
    // the trails of those who crashed last: they flash.
    else if (px_cell[2]) rgb = (round == R_OVER && frame_cnt[3])
                               ? WHITE : pcol(px_cell[1:0]);
    else if (px_grid) rgb = GRID;
    else rgb = BLACK;
  end

  always @(posedge clk) begin
    r <= rgb[5:4];
    g <= rgb[3:2];
    b <= rgb[1:0];
  end

endmodule
