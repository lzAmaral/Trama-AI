#!/bin/sh
# Render the real SwiftUI/AppKit views offscreen with isolated data and a fake RPC engine.
set -eu
TRAMA_PREVIEW_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TRAMA_PREVIEW_ROOT"
swift build
TRAMA_PREVIEW_BIN=$(swift build --show-bin-path)
TRAMA_PREVIEW_OUTPUT="$TRAMA_PREVIEW_ROOT/.build/octo-native-previews"
mkdir -p "$TRAMA_PREVIEW_OUTPUT"
swiftc -parse-as-library -swift-version 6 -I "$TRAMA_PREVIEW_BIN/Modules" \
    "$TRAMA_PREVIEW_ROOT/scripts/render-workspace-preview.swift" \
    -Xlinker -filelist -Xlinker "$TRAMA_PREVIEW_BIN/Trama.product/Objects.LinkFileList" \
    -o "$TRAMA_PREVIEW_OUTPUT/render-preview"
"$TRAMA_PREVIEW_OUTPUT/render-preview" "$TRAMA_PREVIEW_OUTPUT" "$@"
