#!/bin/bash
set -euo pipefail

# Proves the Mach exception monitor works in a process signed with the Enhanced Security
# entitlement com.apple.security.hardened-process.platform-restrictions-string = 2, which kills
# any process that registers an exception port with a behavior exposing control ports.
# Exits 0 when proven, 1 on failure, 75 when the restriction is not in force on this host.

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
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
if [[ "$SKIP_BUILD" == false ]]; then
    xcodebuild -project "$SDK_ROOT/Sentry.xcodeproj" -scheme Sentry \
        -configuration "$CONFIGURATION" -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED_DATA" -disableAutomaticPackageResolution -skipPackageUpdates \
        SDK_STAT_CACHE_ENABLE=NO CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 \
        build >"$OUTPUT_DIRECTORY/build.log" 2>&1
fi

FRAMEWORKS="$DERIVED_DATA/Build/Products/$CONFIGURATION"
PROBE="$OUTPUT_DIRECTORY/SentryHardenedMachExceptionProbe"
ENTITLEMENTS="$OUTPUT_DIRECTORY/platform-restrictions.entitlements"
LOG="$OUTPUT_DIRECTORY/tests.log"
CACHE="$OUTPUT_DIRECTORY/cache"
rm -rf "$CACHE"
: >"$LOG"

xcrun swiftc "$SDK_ROOT/Tests/SentryConsumerTests/SentryHardenedMachExceptionProbe.swift" \
    -swift-version 5 -F "$FRAMEWORKS" -framework Sentry \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -o "$PROBE" >"$OUTPUT_DIRECTORY/compile.log" 2>&1
cat >"$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.hardened-process.platform-restrictions-string</key><string>2</string>
</dict></plist>
PLIST
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$PROBE" >>"$LOG" 2>&1

# Runs one probe mode; records its output and exit status in the log.
run_probe() {
    local mode="$1"
    local status=0
    SENTRY_PROBE_CACHE="$CACHE" "$PROBE" "$mode" >"$OUTPUT_DIRECTORY/$mode.out" 2>&1 || status=$?
    printf '%s: exit %s\n' "$mode" "$status" >>"$LOG"
    sed 's/^/  /' "$OUTPUT_DIRECTORY/$mode.out" >>"$LOG"
    return "$status"
}

finish() {
    printf '\nEXIT=%s\n' "$1" >>"$LOG"
    cat "$LOG"
    exit "$1"
}

CONTROL_STATUS=0
run_probe control || CONTROL_STATUS=$?
if [[ "$CONTROL_STATUS" == 0 ]]; then
    printf '\nThe control registered an EXCEPTION_DEFAULT port and survived, so the restriction is not in force.\n' >>"$LOG"
    finish 75
fi

run_probe start || finish 1
grep -q '^started lastRunDidCrash=false$' "$OUTPUT_DIRECTORY/start.out" || finish 1

CRASH_STATUS=0
run_probe crash || CRASH_STATUS=$?
# SIGSEGV: the monitor declined the exception and the kernel delivered the signal.
[[ "$CRASH_STATUS" == 139 ]] || finish 1

run_probe report || finish 1
grep -q '^started lastRunDidCrash=true$' "$OUTPUT_DIRECTORY/report.out" || finish 1
grep -q '^report mechanism=mach exception=EXC_BAD_ACCESS code=1 subcode=16$' \
    "$OUTPUT_DIRECTORY/report.out" || finish 1
grep -q '^report crashedThreadIsMain=true crashedThreadHasFrames=true$' "$OUTPUT_DIRECTORY/report.out" || finish 1
finish 0
