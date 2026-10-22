#!/bin/sh
# Runs every test; stops at the first failure.
set -e
cd "$(dirname "$0")/.."
export LUA_PATH="portable_config/scripts/midframe/?.lua;tests/?.lua;;"
for t in tests/test_*.lua; do echo "== $t"; lua "$t"; done
echo "== tests/test_mf_vs.py"; python3 tests/test_mf_vs.py
echo "== tests/test_vs_build.py"; "${VS_PYTHON:-python3}" tests/test_vs_build.py  # set VS_PYTHON to a python with vapoursynth
echo "all tests passed"
