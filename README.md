![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Tron

[![Made with Claude](https://img.shields.io/badge/Made%20with-Claude-D97757?logo=anthropic&logoColor=white)](https://claude.com/claude-code)

Four player light cycles for Tiny Tapeout: 800x600 VGA, raced against the beam, played with the Gamepad Pmod. Two players share each SNES controller and use just two buttons each. See [docs/info.md](docs/info.md) for how it works and how to play.

`sim/tron_demo.html` is the browser prototype used to size the trail memory. It has the same rules, with one human against three bots.

## Status

| | |
|---|---|
| FPGA | Runs on the TT FPGA breakout with the Gamepad Pmod (flash with `PORT=/dev/ttyACM1` on this bench). 2271 / 5280 logic cells (43%) on the UP5K, 1 / 30 block RAM. nextpnr reports 40.3–41.1 MHz over seeds 0–3 against the 40 MHz target |
| Tests | cocotb, all passing under Verilator. Includes a randomised check of every cell against a Python model, covering wraps and ring overflow |
| ASIC | Not hardened yet. `info.yaml` says 4x2 as a placeholder |

## Toolchain

oss-cad-suite has to be on PATH, including its Python, which has cocotb:

    source ~/oss-cad-suite/environment

## Commands

    make lint                     # verilator -Wall
    make bitstream                # yosys + nextpnr + icepack for the TT FPGA breakout
    make flash PORT=/dev/ttyACM0  # upload to the demoboard (needs tt-support-tools' venv)
    make -C test SIM=verilator EXTRA_ARGS=--timing   # cocotb suite, about 6 minutes

`make bitstream` mirrors `tt_fpga.py harden`, following `../../shuttle-ttihp26a/multi-seg-monitor`. `TT_TOOLS` defaults to `~/work/asic-workshop/tinytapeout/tt-support-tools`.

Under Icarus, the default and what CI runs, a frame takes about 40 seconds against Verilator's 0.7. So the model test skips itself under Icarus unless `MODEL_FRAMES` is set, and `test_round` takes about 15 minutes.

Each test saves the frames it captures as PNGs in `test/`. Waveforms are off by default: `make -C test PLUSARGS=+fst`.
