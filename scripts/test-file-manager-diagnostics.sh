#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pre-commit does not follow sourced helpers; ci-utils.sh is linted separately.
# shellcheck source=./ci-utils.sh disable=SC1091
source "$SCRIPT_DIR/ci-utils.sh"
DERIVED_DATA=""
OUTPUT_DIRECTORY=""
CONFIGURATION="Debug"
SKIP_BUILD=false

usage() {
    log_notice "Usage: $0 --derived-data <path> --output-directory <path> [--configuration Debug|Release] [--skip-build]"
    exit 64
}

while [[ $# -gt 0 ]]; do
    case $1 in
    --derived-data)
        DERIVED_DATA="${2:?}"
        shift 2
        ;;
    --output-directory)
        OUTPUT_DIRECTORY="${2:?}"
        shift 2
        ;;
    --configuration)
        CONFIGURATION="${2:?}"
        shift 2
        ;;
    --skip-build)
        SKIP_BUILD=true
        shift
        ;;
    *) usage ;;
    esac
done

[[ -n "$DERIVED_DATA" && -n "$OUTPUT_DIRECTORY" ]] || usage
[[ "$CONFIGURATION" == Debug || "$CONFIGURATION" == Release ]] || usage
SDK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$OUTPUT_DIRECTORY"
if [[ "$SKIP_BUILD" == false ]]; then
    xcodebuild -project "$SDK_ROOT/Sentry.xcodeproj" -scheme Sentry \
        -configuration "$CONFIGURATION" -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED_DATA" -disableAutomaticPackageResolution -skipPackageUpdates \
        SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 \
        build >"$OUTPUT_DIRECTORY/build.log" 2>&1
fi

FRAMEWORKS="$DERIVED_DATA/Build/Products/$CONFIGURATION"
DEVELOPER_FRAMEWORKS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
DEVELOPER_LIB="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
TEST_BUNDLE="$OUTPUT_DIRECTORY/SentryFileManagerDiagnosticsTests.xctest"
mkdir -p "$TEST_BUNDLE/Contents/MacOS"
cat >"$TEST_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SentryFileManagerDiagnosticsTests</string>
<key>CFBundleIdentifier</key><string>io.sentry.consumer-file-manager-tests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
xcrun swiftc "$SDK_ROOT/Tests/SentryConsumerTests/SentryFileManagerDiagnosticsTests.swift" \
    -emit-library -module-name SentryConsumerTests -I "$DEVELOPER_LIB" -L "$DEVELOPER_LIB" \
    -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$DEVELOPER_LIB" \
    -swift-version 5 -F "$FRAMEWORKS" -F "$DEVELOPER_FRAMEWORKS" \
    -framework Sentry -framework XCTest -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$DEVELOPER_FRAMEWORKS" \
    -o "$TEST_BUNDLE/Contents/MacOS/SentryFileManagerDiagnosticsTests" >"$OUTPUT_DIRECTORY/compile.log" 2>&1

set +e
LLVM_PROFILE_FILE="$OUTPUT_DIRECTORY/%p.profraw" xcrun xctest "$TEST_BUNDLE" >"$OUTPUT_DIRECTORY/tests.log" 2>&1
RESULT=$?
set -e
if [[ "$RESULT" == 0 ]] && ! grep -Eq 'Executed 2 tests, with 0 failures' "$OUTPUT_DIRECTORY/tests.log"; then
    printf '\nExpected both diagnostic tests to execute without skips.\n' >>"$OUTPUT_DIRECTORY/tests.log"
    RESULT=75
fi
printf '\nEXIT=%s\n' "$RESULT" >>"$OUTPUT_DIRECTORY/tests.log"
cat "$OUTPUT_DIRECTORY/tests.log"
exit "$RESULT"
