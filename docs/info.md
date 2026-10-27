## How it works

Four player light cycles on an 800x600 VGA screen. Each player leaves a trail, and running into any trail, or into another player head on, is fatal. The last player alive wins the round and gets a pip in the score strip along the bottom of the screen, up to 12 each. The edges wrap: leave the left side and you come back on the right, and the same for top and bottom.

The playfield is a 50x37 grid of 16 pixel cells. There is no framebuffer. Each trail is stored as a list of corners in one shared 64 entry ring, 16 bits per entry: the owner, the direction it left in, and the cell. Wraps need no entries, because a straight segment can't go all the way round without hitting its own start. When the ring is full the newest corner overwrites the oldest, so the oldest trail loses its tail rather than the game running out of memory.

A query engine works out who owns any cell by scanning the ring, one entry per clock, then the four live segments from each player's newest corner to its head. The renderer asks it about all 50 cells of the next row while the current row is on screen, filling a line buffer. The game tick asks it about the cell each head is about to enter during vertical blank, which is all the collision detection there is. Bots use it in the same way to look ahead, left and right before they move.

## How to test

Plug in a Tiny VGA Pmod and a Gamepad Pmod with one or two SNES controllers. Set ui[1:0] for the speed: 0 for 10 moves a second, 1 for 15, 2 for 8.6. Press Start on either controller to start a round.

Each controller is shared by two players, who each use only two buttons to turn left or right relative to the way they are heading:

| Player | Colour | Controller | Left | Right |
|---|---|---|---|---|
| 0 | cyan | 1 | D-pad left | D-pad right |
| 1 | orange | 1 | Y | A |
| 2 | magenta | 2 | D-pad left | D-pad right |
| 3 | lime | 2 | Y | A |

Any player nobody is controlling is played by a bot: it drives straight on, turns into a free cell when it is about to hit something, and now and then turns at random. A player becomes human, for good until reset, as soon as one of its turn buttons is pressed on a plugged in controller. So to join, press one of your turn buttons before pressing Start; it won't turn you until the round starts.

With no human players at all, rounds start by themselves after about a second, so the bots play an attract mode.

## External hardware

- [Tiny VGA Pmod](https://github.com/mole99/tiny-vga) on the output pins
- [Gamepad Pmod](https://github.com/psychogenic/gamepad-pmod) on the input pins, with one or two SNES compatible controllers
