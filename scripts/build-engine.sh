#!/bin/sh
set -eu
TRAMA_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TRAMA_ROOT"
./scripts/cargo-local.sh build --locked --manifest-path Engine/Cargo.toml --target-dir "$TRAMA_ROOT/Engine/target"
swift build
TRAMA_BIN=$(swift build --show-bin-path)
cp Engine/target/debug/trama-engine "$TRAMA_BIN/trama-engine"
printf 'Motor disponível em %s/trama-engine\n' "$TRAMA_BIN"
