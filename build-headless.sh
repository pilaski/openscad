#!/usr/bin/env bash
# Detached Phase-1 build runner for OpenSCAD headless (Linux).
# Memory-constrained host (~4.7G free, CGAL TUs are RAM-hungry) -> low parallelism.
# Writes progress to build.log and a final status to build.status.
set -o pipefail
BUILD_DIR="/home/claire/.openclaw/workspace/repos/openscad/build"
JOBS="${1:-2}"
cd "$BUILD_DIR" || { echo "no build dir" > build.status; exit 1; }
echo "START $(date -Is) jobs=$JOBS" > build.status
ninja -j"$JOBS" > build.log 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ -x "$BUILD_DIR/openscad" ]; then
  echo "DONE_OK rc=$RC $(date -Is)" >> build.status
else
  echo "DONE_FAIL rc=$RC $(date -Is)" >> build.status
fi
