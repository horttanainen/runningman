#!/bin/sh
set -eu

zig fmt build.zig src
zig build
zig build test
sh -n scripts/import-polar scripts/import-garmin tests/polar-import.sh tests/garmin-import.sh
./scripts/import-polar --build-only
./scripts/import-garmin --build-only
sh tests/polar-import.sh
sh tests/garmin-import.sh
