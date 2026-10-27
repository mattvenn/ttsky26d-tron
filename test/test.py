# SPDX-FileCopyrightText: © 2026 Matt Venn
# SPDX-License-Identifier: Apache-2.0

import os
import struct
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

CLK_NS = 25  # 40 MHz
H_TOTAL = 1056
V_TOTAL = 628
CELL = 16

# RGB222 player colours as (r, g, b), matching pcol() in src/tron.v
COLOURS = [(0, 3, 3), (3, 2, 0), (3, 0, 3), (2, 3, 0)]
WHITE = (3, 3, 3)
BLACK = (0, 0, 0)
GRID = (0, 0, 1)

# Start cells: (x, y), matching start_pos() in src/tron.v
STARTS = [(12, 9), (37, 9), (37, 27), (12, 27)]

# SNES button order in each controller's 12 bit word, first bit shifted out first
BUTTONS = ["b", "y", "select", "start", "up", "down", "left", "right", "a", "x", "l", "r"]


class Gamepads:
    """Drives the Gamepad Pmod's latch / clock / data pins on ui_in[6:4].

    Sends both controllers' 24 bits every `period` clocks, like the Pmod's
    own firmware does. A controller that is not plugged in reads as all ones.
    """

    def __init__(self, dut, present=(True, True), period=20000):
        self.dut = dut
        self.present = list(present)
        self.pressed = [set(), set()]
        self.period = period
        self.sent = 0

    def word(self, pad):
        if not self.present[pad]:
            return 0xFFF
        w = 0
        for name in BUTTONS:
            w = (w << 1) | (1 if name in self.pressed[pad] else 0)
        return w

    def set_pins(self, latch, clk, data):
        v = int(self.dut.ui_in.value) & ~0x70
        self.dut.ui_in.value = v | (latch << 4) | (clk << 5) | (data << 6)

    async def send(self):
        # Controller 2 first: it ends up in the driver's top 12 bits.
        bits = (self.word(1) << 12) | self.word(0)
        for i in range(23, -1, -1):
            d = (bits >> i) & 1
            self.set_pins(0, 0, d)
            await ClockCycles(self.dut.clk, 4)
            self.set_pins(0, 1, d)  # sampled on the rising edge
            await ClockCycles(self.dut.clk, 4)
        self.set_pins(1, 0, 0)  # latch rising edge moves it to data_reg
        await ClockCycles(self.dut.clk, 4)
        self.set_pins(0, 0, 0)
        self.sent += 1

    async def run(self):
        while True:
            await self.send()
            await Timer(self.period * CLK_NS, unit="ns")

    async def press(self, pad, button):
        await self.press_many([(pad, button)])

    async def press_many(self, presses):
        """Hold buttons, as (pad, button), for two complete updates, then release them."""
        for pad, button in presses:
            self.pressed[pad].add(button)
        target = self.sent + 2
        while self.sent < target:
            await Timer(1000 * CLK_NS, unit="ns")
        for pad, button in presses:
            self.pressed[pad].discard(button)
        target = self.sent + 2
        while self.sent < target:
            await Timer(1000 * CLK_NS, unit="ns")


async def setup(dut, speed=3, pads=None):
    clock = Clock(dut.clk, CLK_NS, unit="ns")
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = speed & 3
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    if pads is not None:
        cocotb.start_soon(pads.run())


def vsync(dut):
    return dut.vsync  # tb.v wire: uo_out[3]


async def next_vblank(dut):
    """Wait for the start of a vsync pulse (the game ticks just before it)."""
    await FallingEdge(vsync(dut))


async def capture_frame(dut, name):
    """Capture the next whole frame from the pins (see tb.v), save a PNG."""
    dut.capture.value = 1
    await RisingEdge(vsync(dut))  # capture starts here
    await RisingEdge(vsync(dut))  # and ends here
    await ClockCycles(dut.clk, 2)
    pixels = read_ppm("frame.ppm")
    write_png(f"{name}.png", pixels)
    return pixels


def read_ppm(path):
    with open(path) as f:
        tokens = f.read().split()
    assert tokens[0] == "P3"
    w, h = int(tokens[1]), int(tokens[2])
    vals = list(map(int, tokens[4:]))
    assert len(vals) == w * h * 3, f"short frame: {len(vals) // 3} of {w * h} pixels"
    return [[tuple(vals[(y * w + x) * 3:(y * w + x) * 3 + 3]) for x in range(w)] for y in range(h)]


def write_png(path, pixels):
    h, w = len(pixels), len(pixels[0])
    raw = b"".join(b"\x00" + bytes(c * 85 for p in row for c in p) for row in pixels)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw)))
        f.write(chunk(b"IEND", b""))


def cell(pixels, x, y):
    """Colour at the middle of grid cell (x, y)."""
    return pixels[y * CELL + CELL // 2][x * CELL + CELL // 2]


@cocotb.test()
async def test_sync_timing(dut):
    """800x600@60: 1056 clocks per line, 628 lines per frame."""
    await setup(dut)
    hs = dut.hsync  # tb.v wire: uo_out[7]
    await FallingEdge(hs)
    t0 = get_sim_time("ns")
    await FallingEdge(hs)
    assert get_sim_time("ns") - t0 == H_TOTAL * CLK_NS

    await FallingEdge(vsync(dut))
    t0 = get_sim_time("ns")
    await FallingEdge(vsync(dut))
    assert get_sim_time("ns") - t0 == H_TOTAL * V_TOTAL * CLK_NS


@cocotb.test()
async def test_attract(dut):
    """With no controllers, all four players wait at their start cells."""
    await setup(dut, pads=Gamepads(dut, present=(False, False)))
    await next_vblank(dut)
    px = await capture_frame(dut, "frame_ready")

    for p, (x, y) in enumerate(STARTS):
        # Heads blink between white and the player's colour while waiting.
        assert cell(px, x, y) in (WHITE, COLOURS[p]), f"player {p} head: {cell(px, x, y)}"
    # Empty cells are black with a dark blue grid on the cell edges.
    assert cell(px, 0, 0) == BLACK
    assert px[0][0] == GRID and px[16][5] == GRID and px[5][16] == GRID
    # Nothing in the score strip yet.
    assert all(p == BLACK for row in px[592:600] for p in row)


@cocotb.test()
async def test_round(dut):
    """A scripted round with two controllers, one move per frame.

    Player 0 turns down on the first move and meets player 3 head on at
    (12, 18) on move 9; both die and their trails vanish. Player 1 runs
    down into player 2's start corner on move 18, so player 2 wins.
    """
    pads = Gamepads(dut, present=(True, True))
    await setup(dut, speed=3, pads=pads)
    await next_vblank(dut)          # round set up, waiting for start

    # Everyone presses a turn button to join; until then they'd be bots.
    # Turns aren't queued before the round starts, so nobody turns.
    await pads.press_many([(0, "left"), (0, "y"), (1, "left"), (1, "y")])
    await pads.press(1, "start")
    await next_vblank(dut)          # start taken: playing, first move next vblank
    await pads.press(0, "right")    # player 0: turn right, from right to down

    for _ in range(5):
        await next_vblank(dut)
    px = await capture_frame(dut, "frame_move5")
    # Five moves in: player 0's trail runs down from its start, player 3's up.
    for k in range(6):
        assert cell(px, 12, 9 + k) in (COLOURS[0], WHITE), f"player 0 at y={9 + k}"
        assert cell(px, 12, 27 - k) in (COLOURS[3], WHITE), f"player 3 at y={27 - k}"
    assert cell(px, 12, 14) == WHITE and cell(px, 12, 22) == WHITE  # heads
    assert cell(px, 13, 9) == BLACK  # player 0 did not go right

    for _ in range(14):
        await next_vblank(dut)
    px = await capture_frame(dut, "frame_over")
    # Only player 2's trail is left: its start corner to its head at x=19.
    for x in range(19, 38):
        assert cell(px, x, 27) in (COLOURS[2], WHITE), f"player 2 at x={x}"
    for x, y in [(12, 9), (12, 14), (12, 22), (37, 9), (37, 20)]:
        assert cell(px, x, y) == BLACK, f"dead trail left at ({x}, {y})"
    # One win pip for player 2 in the score strip, nobody else. Each player
    # has a quarter of the width.
    assert px[595][400 + 8] == COLOURS[2]
    assert px[595][400 + 16 + 8] == BLACK
    assert px[595][8] == BLACK and px[595][200 + 8] == BLACK and px[595][600 + 8] == BLACK


# ---------------------------------------------------------------------------
# Reference model: the game as the RTL plays it, but drawing trails by
# walking them cell by cell rather than the RTL's modular range test.

GW, GH, RING = 50, 37, 64
STEP = [(1, 0), (0, 1), (-1, 0), (0, -1)]  # right, down, left, up
START_DIRS = [0, 1, 2, 3]
READY, PLAY, OVER = range(3)

# Each player's (controller, left button, right button)
CONTROLS = [(0, "left", "right"), (0, "y", "a"), (1, "left", "right"), (1, "y", "a")]


class Model:
    def __init__(self):
        self.round = READY
        self.need_init = True
        self.start_pending = False
        self.queue = [[] for _ in range(4)]
        self.score = [0] * 4
        self.winner = None
        self.drops = 0
        self.wraps = 0

    def init(self, next_round):
        self.heads = [list(s) for s in STARTS]
        self.dirs = list(START_DIRS)
        self.alive = [True] * 4
        # Start points are tails, outside the ring; the ring holds turns.
        self.tails = [(p, self.dirs[p], *STARTS[p]) for p in range(4)]
        self.ring = []
        self.round = next_round
        self.winner = None

    def press_start(self):
        if self.round != PLAY:
            self.start_pending = True

    def press_turn(self, p, turn):
        if self.round == PLAY and len(self.queue[p]) < 2:
            self.queue[p].append(turn)

    def trail_cells(self, p):
        """Cells of player p's trail, from its entries in the ring and its head."""
        corners = [self.tails[p]] + [e for e in self.ring if e[0] == p]
        cells = {tuple(self.heads[p])}
        ends = [(e[2], e[3]) for e in corners[1:]] + [tuple(self.heads[p])]
        for (o, d, x, y), end in zip(corners, ends):
            while (x, y) != end:
                cells.add((x, y))
                x, y = (x + STEP[d][0]) % GW, (y + STEP[d][1]) % GH
        return cells

    def owners(self):
        grid = {}
        for p in range(4):
            if self.alive[p]:
                for c in self.trail_cells(p):
                    grid[c] = p
        return grid

    def tick(self):
        for p in range(4):
            if self.queue[p]:
                turn = self.queue[p].pop(0)
                if self.alive[p]:
                    self.dirs[p] = (self.dirs[p] + (1 if turn == "right" else 3)) % 4
                    self.ring.append((p, self.dirs[p], *self.heads[p]))
                    if len(self.ring) > RING:
                        dropped = self.ring.pop(0)
                        self.tails[dropped[0]] = dropped
                        self.drops += 1
        grid = self.owners()
        targets = {}
        for p in range(4):
            if self.alive[p]:
                x, y = self.heads[p]
                nx, ny = x + STEP[self.dirs[p]][0], y + STEP[self.dirs[p]][1]
                if not (0 <= nx < GW and 0 <= ny < GH):
                    self.wraps += 1
                targets[p] = (nx % GW, ny % GH)
        dead = {p for p, t in targets.items() if t in grid}
        dead |= {p for p, t in targets.items() if list(targets.values()).count(t) > 1}
        for p, t in targets.items():
            if p in dead:
                self.alive[p] = False
            else:
                self.heads[p] = list(t)
        left = [p for p in range(4) if self.alive[p]]
        if len(left) <= 1:
            self.round = OVER
            if left:
                self.winner = left[0]
                self.score[self.winner] = min(7, self.score[self.winner] + 1)

    def vblank(self):
        """What the RTL's G_IDLE does on ev_tick, at speed 3 (a move a frame)."""
        if self.round != PLAY:
            self.queue = [[] for _ in range(4)]
        if self.need_init:
            self.init(READY)
            self.need_init = False
        elif self.start_pending and self.round == READY:
            self.round = PLAY
            self.start_pending = False
        elif self.start_pending and self.round == OVER:
            self.init(PLAY)
            self.start_pending = False
        elif self.round == PLAY:
            self.tick()

    def expected(self):
        """For every cell, the colours it may show this frame (blinks allowed)."""
        grid = self.owners()
        exp = {}
        for y in range(GH):
            for x in range(GW):
                p = grid.get((x, y))
                if p is None:
                    exp[(x, y)] = {BLACK}
                elif [x, y] == self.heads[p]:
                    exp[(x, y)] = {WHITE, COLOURS[p]} if self.round == READY else {WHITE}
                elif self.round == OVER and p == self.winner:
                    exp[(x, y)] = {WHITE, COLOURS[p]}
                else:
                    exp[(x, y)] = {COLOURS[p]}
        return exp


@cocotb.test()
async def test_random_vs_model(dut):
    """Random turns for all four players over many rounds, checked against
    the model every few frames. Covers wrapping and ring overflow."""
    import random
    if cocotb.SIM_NAME.lower().startswith("icarus") and "MODEL_FRAMES" not in os.environ:
        dut._log.info("skipped under Icarus (about 40 s a frame); use SIM=verilator")
        return
    rng = random.Random(1)
    pads = Gamepads(dut, present=(True, True), period=5000)
    await setup(dut, speed=3, pads=pads)
    model = Model()

    async def press_all(presses):
        for pad, button in presses:
            pads.pressed[pad].add(button)
        target = pads.sent + 2
        while pads.sent < target:
            await Timer(500 * CLK_NS, unit="ns")
        for pad, button in presses:
            pads.pressed[pad].discard(button)
        target = pads.sent + 2
        while pads.sent < target:
            await Timer(500 * CLK_NS, unit="ns")

    frames = int(os.environ.get("MODEL_FRAMES", "150"))
    checks = 0
    await next_vblank(dut)
    model.vblank()
    for frame in range(frames):
        presses = []
        if model.round == PLAY:
            # Turn often to fill the ring, but mostly away from a crash so
            # rounds last long enough to overflow it.
            grid = model.owners()
            for p in range(4):
                if not model.alive[p]:
                    continue
                options = {}
                for turn, dd in (("straight", 0), ("left", 3), ("right", 1)):
                    d = (model.dirs[p] + dd) % 4
                    x, y = model.heads[p]
                    options[turn] = ((x + STEP[d][0]) % GW, (y + STEP[d][1]) % GH) not in grid
                safe_turns = [t for t in ("left", "right") if options[t]]
                if safe_turns and (rng.random() < 0.6 or not options["straight"]):
                    turn = rng.choice(safe_turns)
                elif rng.random() < 0.05:
                    turn = rng.choice(["left", "right"])
                else:
                    continue
                model.press_turn(p, turn)
                pad, lb, rb = CONTROLS[p]
                presses.append((pad, lb if turn == "left" else rb))
        else:
            model.press_start()
            presses.append((rng.randrange(2), "start"))
            if frame == 0:
                # All four join as humans, so the model needs no bots.
                presses += [(0, "left"), (0, "y"), (1, "left"), (1, "y")]
        presser = cocotb.start_soon(press_all(presses))

        if frame % 5 == 4:
            exp = model.expected()
            px = await capture_frame(dut, "frame_model")  # ends after the next vblank
            await presser
            bad = [(c, cell(px, *c)) for c, ok in exp.items() if cell(px, *c) not in ok]
            assert not bad, f"frame {frame}: {len(bad)} cells differ, first {bad[:5]}"
            checks += 1
        else:
            await presser
            await next_vblank(dut)
        model.vblank()

    dut._log.info(f"{checks} frames checked, score {model.score}, "
                  f"{model.drops} corners dropped from the full ring, {model.wraps} wraps")
    assert model.drops > 0, "never filled the ring"
    assert model.wraps > 0, "never wrapped"


@cocotb.test()
async def test_bots(dut):
    """With no controllers, bots start a round by themselves after about a
    second, steer around trails, and turn now and then."""
    await setup(dut, speed=3, pads=Gamepads(dut, present=(False, False)))
    for _ in range(64 + 2 + 30):  # waiting, then 30 moves
        await next_vblank(dut)
    px = await capture_frame(dut, "frame_bots")

    cells = {(x, y): cell(px, x, y) for y in range(GH) for x in range(GW)}
    heads = [c for c, v in cells.items() if v == WHITE]
    assert len(heads) >= 2, f"only {len(heads)} bots alive after 30 moves"
    turned = [p for p, (sx, sy) in enumerate(STARTS)
              if any(v == COLOURS[p] and x != sx and y != sy for (x, y), v in cells.items())]
    assert turned, "no bot turned"


@cocotb.test()
async def test_attract_exit(dut):
    """Controllers plugged in but nobody has joined: attract mode starts by
    itself and its rounds may never end, so Start must end it. The lobby
    then waits for players to join and press Start."""
    pads = Gamepads(dut, present=(True, True))
    await setup(dut, speed=3, pads=pads)
    for _ in range(64 + 2 + 10):  # attract round under way
        await next_vblank(dut)

    await pads.press(0, "start")
    await next_vblank(dut)          # round ended, back to the start
    px = await capture_frame(dut, "frame_attract_exit")
    for p, (x, y) in enumerate(STARTS):
        assert cell(px, x, y) in (WHITE, COLOURS[p]), f"player {p} not back at start"
    trail = [c for y in range(GH) for x in range(GW)
             if (x, y) not in STARTS and (c := cell(px, x, y)) != BLACK]
    assert not trail, f"{len(trail)} trail cells left over"

    # The lobby waits: well past the old one second timeout, still there.
    for _ in range(90):
        await next_vblank(dut)
    px = await capture_frame(dut, "frame_lobby_wait")
    for p, (x, y) in enumerate(STARTS):
        assert cell(px, x, y) in (WHITE, COLOURS[p]), f"lobby gave up: player {p} moved"

    # Player 0 joins and starts; the other three stay bots.
    await pads.press(0, "left")
    await pads.press(0, "start")
    await next_vblank(dut)          # playing
    for _ in range(3):
        await next_vblank(dut)
    px = await capture_frame(dut, "frame_after_join")
    # Player 0 went straight on: three moves right of its start.
    for x in range(12, 15):
        assert cell(px, x, 9) in (COLOURS[0], WHITE), f"player 0 at x={x}"
