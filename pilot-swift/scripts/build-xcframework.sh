#!/usr/bin/env bash
# Build Pilot.xcframework from the pilotprotocol Go source.
#
# The binary inside the framework comes from the pilotprotocol Go
# repo's sdk/cgo package. Set $PILOT_REPO to a local clone, or rely
# on the default sibling discovery below.
#
# Produces three slices, then bundles them via xcodebuild
# -create-xcframework:
#
#   ios-arm64                 — iOS device (iPhone/iPad arm64)
#   ios-arm64-simulator       — iOS simulator on Apple Silicon
#   macos-arm64               — macOS arm64 (for tests + local dev)
#
# Re-run is idempotent: Frameworks/Pilot.xcframework is deleted
# before recreating it.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_DIR="$(cd "$THIS_DIR/.." && pwd)"
OUT="$SWIFT_DIR/Frameworks"

# Resolve PILOT_REPO. Order of precedence:
#   1. $PILOT_REPO env var
#   2. ../web4 sibling to this clone
#   3. ../pilotprotocol sibling to this clone
#   4. ~/Development/web4 (fallback for the original author's setup)
if [ -z "${PILOT_REPO:-}" ]; then
    for candidate in \
        "$SWIFT_DIR/../../web4" \
        "$SWIFT_DIR/../../pilotprotocol" \
        "$HOME/Development/web4"
    do
        if [ -d "$candidate" ] && [ -f "$candidate/go.mod" ]; then
            PILOT_REPO="$candidate"
            break
        fi
    done
fi
if [ -z "${PILOT_REPO:-}" ] || [ ! -d "$PILOT_REPO/sdk/cgo" ]; then
    cat >&2 <<EOF
ERROR: cannot find pilotprotocol Go source.
Set PILOT_REPO to point at a clone of github.com/TeoSlayer/pilotprotocol.

    export PILOT_REPO=/path/to/pilotprotocol
    $0
EOF
    exit 1
fi
echo ">>> using PILOT_REPO=$PILOT_REPO"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"
rm -rf "$OUT/Pilot.xcframework"

build_slice() {
    local label="$1" sdk="$2" goarch="$3" minver_flag="$4"
    local out_dir="$WORK/$label"
    mkdir -p "$out_dir/Headers"

    local sdkpath cc
    sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" --find clang) -isysroot $sdkpath -arch $goarch $minver_flag"

    echo ">>> building $label ($sdk / $goarch)"
    CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$cc" \
        go build -C "$PILOT_REPO" \
        -buildmode=c-archive \
        -tags ios \
        -ldflags="-s -w" \
        -o "$out_dir/libPilot.a" \
        ./sdk/cgo

    mv "$out_dir/libPilot.h" "$out_dir/Headers/pilot.h"
    cat > "$out_dir/Headers/module.modulemap" <<'EOF'
module PilotC {
    header "pilot.h"
    link "Pilot"
    export *
}
EOF
}

build_slice "ios-arm64" \
    "iphoneos" "arm64" "-mios-version-min=14.0"

build_slice "ios-arm64-simulator" \
    "iphonesimulator" "arm64" "-mios-simulator-version-min=14.0"

echo ">>> building macos-arm64 (darwin)"
mkdir -p "$WORK/macos-arm64/Headers"
SDK_MAC="$(xcrun --sdk macosx --show-sdk-path)"
CC_MAC="$(xcrun --sdk macosx --find clang) -isysroot $SDK_MAC -arch arm64"
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 CC="$CC_MAC" \
    go build -C "$PILOT_REPO" \
    -buildmode=c-archive \
    -ldflags="-s -w" \
    -o "$WORK/macos-arm64/libPilot.a" \
    ./sdk/cgo
mv "$WORK/macos-arm64/libPilot.h" "$WORK/macos-arm64/Headers/pilot.h"
cat > "$WORK/macos-arm64/Headers/module.modulemap" <<'EOF'
module PilotC {
    header "pilot.h"
    link "Pilot"
    export *
}
EOF

echo ">>> creating Pilot.xcframework"
xcodebuild -create-xcframework \
    -library "$WORK/ios-arm64/libPilot.a" \
    -headers "$WORK/ios-arm64/Headers" \
    -library "$WORK/ios-arm64-simulator/libPilot.a" \
    -headers "$WORK/ios-arm64-simulator/Headers" \
    -library "$WORK/macos-arm64/libPilot.a" \
    -headers "$WORK/macos-arm64/Headers" \
    -output "$OUT/Pilot.xcframework"

echo
echo "✓ built $OUT/Pilot.xcframework"
du -sh "$OUT/Pilot.xcframework"/*/* 2>/dev/null | sort
