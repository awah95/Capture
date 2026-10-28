#!/bin/bash
# Compile or test without installing, launching dictation, or selecting a signing identity.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-debug}"
CONFIGURATION=Debug
case "$ACTION" in
    debug) XCODE_ACTION=build ;;
    release) CONFIGURATION=Release; XCODE_ACTION=build ;;
    test) XCODE_ACTION=test ;;
    *) echo "Usage: $0 [debug|release|test]" >&2; exit 2 ;;
esac
if [[ "$(uname -m)" != arm64 ]]; then
    echo "Capture requires an Apple silicon Mac." >&2
    exit 1
fi
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen" >&2; exit 1; }
CAPTURE_SWIFT_VERSION="$(xcrun swiftc --version | sed -n 's/.*Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
CAPTURE_SWIFT_MAJOR="${CAPTURE_SWIFT_VERSION%%.*}"
CAPTURE_SWIFT_MINOR="${CAPTURE_SWIFT_VERSION#*.}"
if [ -z "$CAPTURE_SWIFT_VERSION" ] \
    || [ "$CAPTURE_SWIFT_MAJOR" -lt 6 ] \
    || { [ "$CAPTURE_SWIFT_MAJOR" -eq 6 ] && [ "$CAPTURE_SWIFT_MINOR" -lt 3 ]; }; then
    echo "Capture requires Swift 6.3 or later. Select Xcode 26.4.1 or later; found ${CAPTURE_SWIFT_VERSION:-unknown}." >&2
    exit 1
fi
xcrun --find metal >/dev/null 2>&1 || {
    echo "Install the Metal compiler: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
}
cd "$REPO"
"$REPO/scripts/bootstrap-moonshine.sh"
xcodegen generate
LOCK_PATH="Captur.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[[ -f Package.resolved ]] || { echo "Missing dependency lock: Package.resolved" >&2; exit 1; }
mkdir -p "$(dirname "$LOCK_PATH")"
cp Package.resolved "$LOCK_PATH"

xcodebuild -project Captur.xcodeproj -scheme Captur \
    -jobs "${CAPTURE_BUILD_JOBS:-2}" -configuration "$CONFIGURATION" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$REPO/build/public" \
    -skipPackagePluginValidation -skipMacroValidation \
    -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO "$XCODE_ACTION"
