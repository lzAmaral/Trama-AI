#!/bin/sh
# Explicit opt-in only. Does not discover identities or change keychain/global settings.
set -eu
TRAMA_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TRAMA_IDENTITY=
TRAMA_PROFILE=
TRAMA_NOTARIZE=false
TRAMA_SOURCE="$TRAMA_ROOT/.build/Trama.app"
usage() {
    cat <<'HELP'
Usage: scripts/distribute-app.sh --identity 'Developer ID Application: Name (TEAM)' [--app PATH] [--notarize --keychain-profile PROFILE]
Copies an already-built app into separate staging, signs with hardened runtime and secure timestamp,
and publishes .build/distribution only after verification. The development bundle is preserved.
--notarize explicitly opts into uploading a ZIP to Apple using an EXISTING keychain profile;
no passwords, profile creation, identity search, releases, or global settings are used.
Without --notarize, output is signed but has NOT been notarized. Gatekeeper and entitlement
compatibility must still be validated on a separate Mac before public distribution.
HELP
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --identity|--app|--keychain-profile)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            case "$1" in
                --identity) TRAMA_IDENTITY=$2 ;;
                --app) TRAMA_SOURCE=$2 ;;
                --keychain-profile) TRAMA_PROFILE=$2 ;;
            esac
            shift 2 ;;
        --notarize) TRAMA_NOTARIZE=true; shift ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "$TRAMA_IDENTITY" in
    'Developer ID Application: '?*) ;;
    *) echo 'An explicit Developer ID Application identity is required.' >&2; exit 2 ;;
esac
if [ "$TRAMA_NOTARIZE" = true ]; then
    [ -n "$TRAMA_PROFILE" ] || { echo '--notarize requires an existing --keychain-profile.' >&2; exit 2; }
elif [ -n "$TRAMA_PROFILE" ]; then
    echo '--keychain-profile requires --notarize.' >&2; exit 2
fi
[ -d "$TRAMA_SOURCE/Contents/MacOS" ] || { echo 'Build the source app first.' >&2; exit 1; }
for TRAMA_TOOL in codesign ditto python3; do
    command -v "$TRAMA_TOOL" >/dev/null 2>&1 || { echo 'Missing distribution tool.' >&2; exit 1; }
done
if [ "$TRAMA_NOTARIZE" = true ]; then
    command -v xcrun >/dev/null 2>&1 || { echo 'Missing xcrun.' >&2; exit 1; }
fi
mkdir -p "$TRAMA_ROOT/.build"
TRAMA_STAGE=$(mktemp -d "$TRAMA_ROOT/.build/distribution-stage.XXXXXX")
trap 'rm -rf "$TRAMA_STAGE"' EXIT
trap 'exit 130' HUP INT TERM
mkdir "$TRAMA_STAGE/artifact"
TRAMA_APP="$TRAMA_STAGE/artifact/Trama.app"
ditto "$TRAMA_SOURCE" "$TRAMA_APP"
# Suppress signing diagnostics: no identity/profile or tool stderr is written to logs.
codesign --force --options runtime --timestamp --sign "$TRAMA_IDENTITY" "$TRAMA_APP/Contents/MacOS/trama-engine" >/dev/null 2>&1 || { echo 'Sidecar signing failed.' >&2; exit 1; }
codesign --force --deep --options runtime --timestamp --sign "$TRAMA_IDENTITY" "$TRAMA_APP" >/dev/null 2>&1 || { echo 'App signing failed.' >&2; exit 1; }
codesign --verify --deep --strict "$TRAMA_APP" >/dev/null 2>&1 || { echo 'Signature verification failed.' >&2; exit 1; }
if [ "$TRAMA_NOTARIZE" = true ]; then
    ditto -c -k --keepParent "$TRAMA_APP" "$TRAMA_STAGE/upload.zip"
    xcrun notarytool submit "$TRAMA_STAGE/upload.zip" --keychain-profile "$TRAMA_PROFILE" --wait --output-format json >"$TRAMA_STAGE/notary.json" 2>/dev/null || { echo 'Apple notarization failed; previous artifacts preserved.' >&2; exit 1; }
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status") == "Accepted" else 1)' "$TRAMA_STAGE/notary.json" || { echo 'Notarization was not accepted.' >&2; exit 1; }
    xcrun stapler staple "$TRAMA_APP" >/dev/null 2>&1 || { echo 'Stapling failed.' >&2; exit 1; }
    xcrun stapler validate "$TRAMA_APP" >/dev/null 2>&1 || { echo 'Staple verification failed.' >&2; exit 1; }
    codesign --verify --deep --strict "$TRAMA_APP" >/dev/null 2>&1 || { echo 'Final signature verification failed.' >&2; exit 1; }
    printf 'Developer ID signed; notarization accepted and ticket validated.\n' > "$TRAMA_STAGE/artifact/status.txt"
else
    printf 'Developer ID signed; NOT notarized.\n' > "$TRAMA_STAGE/artifact/status.txt"
fi
# Recreate archive after stapling so the published ZIP contains the ticket.
ditto -c -k --keepParent "$TRAMA_APP" "$TRAMA_STAGE/artifact/Trama.zip"
python3 "$TRAMA_ROOT/scripts/publish-directory.py" "$TRAMA_STAGE/artifact" "$TRAMA_ROOT/.build/distribution"
printf 'Distribution artifact prepared: %s/.build/distribution\n' "$TRAMA_ROOT"
