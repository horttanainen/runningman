#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

zig fmt . \
  --exclude .zig-cache \
  --exclude .zig-global-cache \
  --exclude zig-out \
  --exclude zig-pkg \
  --exclude artifacts \
  --exclude references \
  --exclude .codex_pdf_tools
