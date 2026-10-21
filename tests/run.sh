#!/bin/sh
# Runs every test; stops at the first failure.
set -e
cd "$(dirname "$0")/.."
export LUA_PATH="portable_config/scripts/framegen/?.lua;tests/?.lua;;"
for t in tests/test_*.lua; do echo "== $t"; lua "$t"; done
echo "== tests/test_fg_vs.py"; python3 tests/test_fg_vs.py
echo "all tests passed"
