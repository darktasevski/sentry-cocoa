#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Disable SC1091 because it won't work with pre-commit
# shellcheck source=./scripts/ci-utils.sh disable=SC1091
source "$SCRIPT_DIR/ci-utils.sh"

begin_group "Selected Xcode Toolchain"
XCODE_VERSION_OUTPUT=$(xcodebuild -version)
XCODE_VERSION=$(echo "$XCODE_VERSION_OUTPUT" | awk '$1 == "Xcode" {print $2}')
if [[ ! "$XCODE_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    log_error "Could not determine the selected Xcode version"
    end_group
    exit 1
fi
log_info "$XCODE_VERSION_OUTPUT"
DIGESTER_PATH=$(xcrun --sdk iphoneos --find swift-api-digester)
log_info "Using swift-api-digester at $DIGESTER_PATH"
end_group

# Build both frameworks at once, as they depend on each other
begin_group "Build Sentry-Dynamic XCFramework"
log_info "Building Sentry-Dynamic slice"
"$SCRIPT_DIR/build-xcframework-slice.sh" "iphoneos" "Sentry" "-Dynamic" "mh_dylib"

log_info "Assembling Sentry-Dynamic xcframework"
"$SCRIPT_DIR/assemble-xcframework.sh" "Sentry" "-Dynamic" "" "iphoneos" "$(pwd)/XCFrameworkBuildPath/archive/Sentry-Dynamic/SDK_NAME.xcarchive"
end_group

begin_group "Build SentrySwiftUI XCFramework"
log_info "Building SentrySwiftUI slice"
"$SCRIPT_DIR/build-xcframework-slice.sh" "iphoneos" "SentrySwiftUI" "" "mh_dylib"

log_info "Assembling SentrySwiftUI xcframework"
"$SCRIPT_DIR/assemble-xcframework.sh" "SentrySwiftUI" "" "" "iphoneos" "$(pwd)/XCFrameworkBuildPath/archive/SentrySwiftUI/SDK_NAME.xcarchive"
end_group

begin_group "Extract Public API"
"$SCRIPT_DIR/extract-swift-api.sh" \
    --module Sentry \
    --output sdk_api.json \
    --framework-path "./Sentry-Dynamic.xcframework/ios-arm64_arm64e"
end_group

begin_group "Extract SentrySwiftUI Public API"
"$SCRIPT_DIR/extract-swift-api.sh" \
    --module SentrySwiftUI \
    --output sdk_api_sentryswiftui.json \
    --framework-path "$(pwd)/SentrySwiftUI.xcframework/ios-arm64_arm64e" \
    --framework-path "$(pwd)/Sentry-Dynamic.xcframework/ios-arm64_arm64e"
end_group

begin_group "Extract SentryObjC Public API"
"$SCRIPT_DIR/extract-objc-api.sh" \
    --output sdk_api_objc.json
end_group

begin_group "Extract SentryObjCCompat Public API"
"$SCRIPT_DIR/extract-objc-compat-api.sh" \
    --output sdk_api_objccompat.json
end_group

begin_group "Diff SentryObjC vs SentryObjCCompat"
"$SCRIPT_DIR/generate-objc-compat-api-diff.sh" \
    --headers sdk_api_objc.json \
    --compat sdk_api_objccompat.json \
    --output sdk_api_objc.diff.json
end_group

# V10 API extraction — rebuilds with ReleaseV10 configuration (SDK_V10 flag)
# to track the V10 API surface separately from the base SDK.
# The V10 configuration uses the same product/module name (Sentry) but
# compiles with SDK_V10=1, so #if SDK_V10 branches are included.

begin_group "Build Sentry-Dynamic V10 XCFramework"
log_info "Building Sentry-Dynamic V10 slice"
"$SCRIPT_DIR/build-xcframework-slice.sh" "iphoneos" "Sentry" "-Dynamic-V10" "mh_dylib" "V10"

log_info "Assembling Sentry-Dynamic V10 xcframework"
# configuration_suffix is empty here because the product name inside the
# archive is still "Sentry.framework" (xcconfig controls PRODUCT_NAME).
"$SCRIPT_DIR/assemble-xcframework.sh" "Sentry" "-Dynamic-V10" "" "iphoneos" "$(pwd)/XCFrameworkBuildPath/archive/Sentry-Dynamic-V10/SDK_NAME.xcarchive"
end_group

begin_group "Extract V10 Public API"
"$SCRIPT_DIR/extract-swift-api.sh" \
    --module Sentry \
    --output sdk_api_v10.json \
    --framework-path "./Sentry-Dynamic-V10.xcframework/ios-arm64_arm64e"
end_group

begin_group "Extract SentryObjC V10 Public API"
"$SCRIPT_DIR/extract-objc-api.sh" \
    --output sdk_api_objc_v10.json \
    --define SDK_V10=1
end_group

begin_group "Extract SentryObjCCompat V10 Public API"
"$SCRIPT_DIR/extract-objc-compat-api.sh" \
    --output sdk_api_objccompat_v10.json \
    --configuration ReleaseV10
end_group

begin_group "Diff SentryObjC vs SentryObjCCompat (V10)"
"$SCRIPT_DIR/generate-objc-compat-api-diff.sh" \
    --headers sdk_api_objc_v10.json \
    --compat sdk_api_objccompat_v10.json \
    --output sdk_api_objc_v10.diff.json
end_group
