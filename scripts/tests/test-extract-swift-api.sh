#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ci-utils.sh disable=SC1091
source "$SCRIPT_DIR/../ci-utils.sh"

WORK_DIR=""

usage() {
    log_notice "Usage: $0 --work-dir <path>"
    log_notice "  --work-dir <path>   Directory for compiled fixture and extraction results (required)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        *) usage ;;
    esac
done

if [ -z "$WORK_DIR" ]; then
    log_error "Error: --work-dir is required"
    usage
fi

mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/mixed-api"
FRAMEWORK_PATH="$WORK_DIR/MixedAPI.xcframework/ios-arm64"
FRAMEWORK="$FRAMEWORK_PATH/MixedAPI.framework"
mkdir -p "$FRAMEWORK/Headers" "$FRAMEWORK/Modules/MixedAPI.swiftmodule"
cp "$FIXTURE_DIR/"*.h "$FRAMEWORK/Headers/"
cp "$FIXTURE_DIR/module.modulemap" "$FRAMEWORK/Modules/"

log_info "Compiling mixed Swift/Objective-C fixture with the selected Xcode"
xcrun --sdk iphoneos swiftc \
    -emit-library -emit-module -enable-library-evolution -swift-version 5 \
    -module-name MixedAPI -import-underlying-module \
    -target arm64-apple-ios10.0 \
    -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -F "$FRAMEWORK_PATH" \
    -emit-module-path "$FRAMEWORK/Modules/MixedAPI.swiftmodule/arm64-apple-ios.swiftmodule" \
    -emit-module-interface-path "$FRAMEWORK/Modules/MixedAPI.swiftmodule/arm64-apple-ios.swiftinterface" \
    -o "$FRAMEWORK/MixedAPI" \
    "$FIXTURE_DIR/MixedAPI.swift"

for run in first second; do
    "$SCRIPT_DIR/../extract-swift-api.sh" \
        --module MixedAPI \
        --output "$WORK_DIR/$run.json" \
        --framework-path "$FRAMEWORK_PATH"

    jq -e 'any(.. | objects; .kind? == "TypeDecl" and .name? == "MixedAPISwift" and (.usr? | startswith("s:")))' "$WORK_DIR/$run.json" >/dev/null || {
        log_error "Missing Swift declaration from the main module"
        exit 1
    }
    log_info "Swift sentinel present: MixedAPISwift"
    jq -e 'any(.. | objects; .usr? == "c:objc(cs)MixedAPIObjC")' "$WORK_DIR/$run.json" >/dev/null || {
        log_error "Missing Objective-C declaration from the header submodule: MixedAPIObjC"
        exit 1
    }
done

cmp "$WORK_DIR/first.json" "$WORK_DIR/second.json"

if "$SCRIPT_DIR/../extract-swift-api.sh" \
    --module MissingMixedAPIModule \
    --output "$WORK_DIR/missing.json" \
    --framework-path "$FRAMEWORK_PATH" >"$WORK_DIR/missing.log" 2>&1; then
    log_error "Extractor succeeded despite a module-load failure"
    exit 1
fi
if ! grep -q 'Failed to load module: MissingMixedAPIModule' "$WORK_DIR/missing.log"; then
    log_error "Missing-module extraction failed without a module-load diagnostic"
    exit 1
fi

log_info "PASS: Swift and Objective-C declarations retained, output stable, module-load failures rejected"
