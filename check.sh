#!/bin/sh
set -eu

bash scripts/format.sh
zig build
zig build test
sh -n \
    scripts/decrypt-data \
    scripts/encrypt-data \
    scripts/import-polar \
    scripts/import-garmin \
    tests/decrypt-data.sh \
    tests/encrypt-data.sh \
    tests/polar-import.sh \
    tests/garmin-import.sh
./scripts/import-polar --build-only
./scripts/import-garmin --build-only
sh tests/decrypt-data.sh
sh tests/encrypt-data.sh
sh tests/polar-import.sh
sh tests/garmin-import.sh
