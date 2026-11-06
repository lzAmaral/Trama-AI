#!/bin/sh
# Development bundle only: ad-hoc signing is not Developer ID distribution.
set -eu
TRAMA_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TRAMA_CONFIGURATION=debug
case "${1:-}" in
    "") ;;
    --release) TRAMA_CONFIGURATION=release ;;
    *) echo 'Uso: ./scripts/package-app.sh [--release]' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo 'Uso: ./scripts/package-app.sh [--release]' >&2
    exit 2
fi
cd "$TRAMA_ROOT"
if [ "$TRAMA_CONFIGURATION" = release ]; then
    ./scripts/cargo-local.sh build --locked --release --manifest-path Engine/Cargo.toml --target-dir "$TRAMA_ROOT/Engine/target"
else
    ./scripts/cargo-local.sh build --locked --manifest-path Engine/Cargo.toml --target-dir "$TRAMA_ROOT/Engine/target"
fi
swift build --configuration "$TRAMA_CONFIGURATION"
TRAMA_BIN=$(swift build --configuration "$TRAMA_CONFIGURATION" --show-bin-path)
TRAMA_STAGE=$(mktemp -d "$TRAMA_ROOT/.build/package.XXXXXX")
trap 'rm -rf "$TRAMA_STAGE"' EXIT HUP INT TERM
TRAMA_APP="$TRAMA_STAGE/Trama.app"
mkdir -p "$TRAMA_APP/Contents/MacOS" "$TRAMA_APP/Contents/Resources"
cp scripts/Info.plist "$TRAMA_APP/Contents/Info.plist"
cp "$TRAMA_BIN/Trama" "$TRAMA_APP/Contents/MacOS/Trama"
cp "Engine/target/$TRAMA_CONFIGURATION/trama-engine" "$TRAMA_APP/Contents/MacOS/trama-engine"
# SwiftTerm at the pinned revision probes Bundle.main.resourceURL directly.
# Its generated SwiftPM Bundle.module accessor is deliberately unused upstream.
for TRAMA_RESOURCE in "$TRAMA_BIN"/*.bundle; do
    [ -d "$TRAMA_RESOURCE" ] || continue
    cp -R "$TRAMA_RESOURCE" "$TRAMA_APP/Contents/Resources/"
done
if [ ! -d "$TRAMA_APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle" ]; then
    echo 'Recursos SwiftTerm ausentes; bundle não foi publicado.' >&2
    exit 1
fi
cp -R ThirdPartyNotices "$TRAMA_APP/Contents/Resources/ThirdPartyNotices"
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$TRAMA_APP/Contents/MacOS/trama-engine"
    codesign --force --deep --sign - "$TRAMA_APP"
    codesign --verify --deep --strict "$TRAMA_APP"
else
    echo 'codesign indisponível: bundle local sem assinatura.' >&2
fi
# Replace only the generated artifact after the new bundle is complete.
rm -rf "$TRAMA_ROOT/.build/Trama.app"
mv "$TRAMA_APP" "$TRAMA_ROOT/.build/Trama.app"
printf 'Bundle local (%s): %s/.build/Trama.app\n' "$TRAMA_CONFIGURATION" "$TRAMA_ROOT"
