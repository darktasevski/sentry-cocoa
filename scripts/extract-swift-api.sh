#!/bin/bash
set -euo pipefail

# Extract public Swift and imported Objective-C API using swift-api-digester.
#
# Runs swift-api-digester on a built xcframework to produce a stable JSON
# dump of the module's public API surface. Used by update-api.sh for
# Sentry and SentrySwiftUI modules.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ci-utils.sh disable=SC1091
source "$SCRIPT_DIR/ci-utils.sh"

MODULE=""
OUTPUT=""
FRAMEWORK_PATHS=()

usage() {
    log_notice "Usage: $0"
    log_notice "  --module <name>           Swift module name (required)"
    log_notice "  --output <path>           Output JSON file path (required)"
    log_notice "  --framework-path <path>   Framework search path (required, repeatable)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --module)         MODULE="$2";                          shift 2 ;;
        --output)         OUTPUT="$2";                          shift 2 ;;
        --framework-path) FRAMEWORK_PATHS+=("$2");              shift 2 ;;
        *)                usage ;;
    esac
done

if [ -z "$MODULE" ]; then
    log_error "Error: --module is required"
    usage
fi

if [ -z "$OUTPUT" ]; then
    log_error "Error: --output is required"
    usage
fi

if [ ${#FRAMEWORK_PATHS[@]} -eq 0 ]; then
    log_error "Error: at least one --framework-path is required"
    usage
fi

# Delete private .swiftinterface files from each framework path so only
# public interfaces are analyzed.
for fw_path in "${FRAMEWORK_PATHS[@]}"; do
    log_info "Deleting private .swiftinterface files from $fw_path"
    # The framework path points inside the xcframework (e.g. .../ios-arm64_arm64e).
    # Walk up one level to find the xcframework root for the find.
    xcfw_root="$(dirname "$fw_path")"
    find "$xcfw_root" -name "*.private.swiftinterface" -type f -delete
done

# Use the selected toolchain's framework search path option.
FRAMEWORK_ARGS=()
for fw_path in "${FRAMEWORK_PATHS[@]}"; do
    FRAMEWORK_ARGS+=("-F" "$fw_path")
done

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

DIGESTER_ARGS=(
    -dump-sdk
    -abort-on-module-fail
    -avoid-tool-args
    -avoid-location
    -module "$MODULE"
    -target arm64-apple-ios10.0
    "${FRAMEWORK_ARGS[@]}"
)

log_info "Running swift-api-digester for $MODULE module"
xcrun --sdk iphoneos swift-api-digester \
    "${DIGESTER_ARGS[@]}" -o "$TEMP_DIR/main.json"

# Current importers represent a mixed framework's Objective-C headers as
# submodule imports. Request only this module's headers, not its dependencies.
jq -r --arg prefix "$MODULE." \
    '.ABIRoot.children[]? | select(.kind == "Import" and (.name | startswith($prefix))) | .name' \
    "$TEMP_DIR/main.json" | LC_ALL=C sort -u > "$TEMP_DIR/header-modules.txt"

if [ -s "$TEMP_DIR/header-modules.txt" ]; then
    # Header submodules can import <Module/Header.h> while being loaded on their
    # own. Give Clang that include layout without changing the built framework.
    mkdir "$TEMP_DIR/includes"
    for fw_path in "${FRAMEWORK_PATHS[@]}"; do
        if [ -d "$fw_path/$MODULE.framework/Headers" ] && [ ! -e "$TEMP_DIR/includes/$MODULE" ]; then
            ln -s "$(cd "$fw_path/$MODULE.framework/Headers" && pwd)" "$TEMP_DIR/includes/$MODULE"
        fi
    done

    log_info "Including $MODULE Objective-C header submodules"
    xcrun --sdk iphoneos swift-api-digester \
        "${DIGESTER_ARGS[@]}" \
        -module-list-file "$TEMP_DIR/header-modules.txt" \
        -I "$TEMP_DIR/includes" \
        -o "$TEMP_DIR/complete.json"
else
    mv "$TEMP_DIR/main.json" "$TEMP_DIR/complete.json"
fi

log_info "Sorting JSON keys and arrays for stable output"
jq -S 'walk(if type == "array" then sort_by(tostring) else . end)' "$TEMP_DIR/complete.json" > "$OUTPUT.tmp" && mv "$OUTPUT.tmp" "$OUTPUT"

log_info "$MODULE API written to $OUTPUT"
