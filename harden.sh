#!/bin/bash
# Harden locally with tt-support-tools inside the iic-osic-tools container
# (LibreLane and the sky130A PDK come from the image).
#
#   ./harden.sh            # tiles from info.yaml
#   ./harden.sh 2x2        # override the tile count for this run only
#
# Results land in runs/wokwi as they would in CI. The few tt-support-tools
# Python dependencies the image lacks are installed once into
# .pydeps (gitignored) and reused.
set -e

PROJECT=$(cd "$(dirname "$0")" && pwd)
TT_TOOLS=${TT_TOOLS:-$HOME/work/asic-workshop/tinytapeout/tt-support-tools}
IMAGE=${IMAGE:-hpretl/iic-osic-tools:2026.05}
PYDEPS=$PROJECT/.pydeps
mkdir -p "$PYDEPS" "$PROJECT/tt"  # tt: where tt_tool expects itself, as in CI

TILES=${1:-}

docker run --rm -u "$(id -u):$(id -g)" \
    -e HOME=/tmp -e TILES="$TILES" \
    -v "$PROJECT":/work -v "$TT_TOOLS":/work/tt:ro -v "$PYDEPS":/pydeps \
    -w /work --entrypoint bash "$IMAGE" -c '
set -e
source /headless/.bashrc >/dev/null 2>&1 || true
export PYTHONPATH=/pydeps:$PYTHONPATH
# Only what the image lacks, without dependencies: a full install of
# tt-support-tools requirements shadows the klayout, numpy etc.
python3 -c "import chevron, git" 2>/dev/null ||
    pip install -q --no-deps --target /pydeps chevron gitpython gitdb smmap
if [ -n "$TILES" ]; then
    # A scratch copy of info.yaml with the tile count changed.
    sed -E "s/^(  tiles: *)\"[0-9]x[0-9]\"/\1\"$TILES\"/" info.yaml > /tmp/info.yaml
    cp info.yaml /tmp/info.yaml.orig
    cp /tmp/info.yaml info.yaml
    trap "cp /tmp/info.yaml.orig /work/info.yaml" EXIT
fi
grep -E "^  tiles:" info.yaml
python3 tt/tt_tool.py --create-user-config
# tt_tool --harden wants a git remote for its commit record; this is the
# librelane call it makes.
rm -rf runs/wokwi && mkdir -p runs/wokwi
# The image defaults to IHP; use its sky130A as installed rather than have
# ciel fetch the exact version LibreLane pins.
export PDK=sky130A STD_CELL_LIBRARY=sky130_fd_sc_hd
python3 -m librelane --pdk-root "$PDK_ROOT" --pdk sky130A --scl sky130_fd_sc_hd --manual-pdk --run-tag wokwi --force-run-dir runs/wokwi \
    --hide-progress-bar src/config_merged.json
'
