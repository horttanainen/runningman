#!/bin/sh
set -eu

zig fmt build.zig src
zig build
zig build test
sh -n scripts/import-polar tests/polar-import.sh
./scripts/import-polar --build-only
sh tests/polar-import.sh
