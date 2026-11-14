#!/bin/sh
set -eu
TRAMA_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -x "$TRAMA_ROOT/.build/toolchains/cargo/bin/cargo" ]; then
    export CARGO_HOME="$TRAMA_ROOT/.build/toolchains/cargo"
    export RUSTUP_HOME="$TRAMA_ROOT/.build/toolchains/rustup"
    export PATH="$CARGO_HOME/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo 'Instale Rust 1.88+ via rustup para compilar o motor.' >&2
    exit 1
fi
exec cargo "$@"
