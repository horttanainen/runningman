#!/bin/sh
set -eu

zig fmt build.zig src
zig build
zig build test
