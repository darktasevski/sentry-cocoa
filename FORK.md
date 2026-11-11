# Reader App consent-lifetime distribution

This maintained fork provides the Sentry correction needed by Reader App #2673.
Deferred crash, hang, and breadcrumb work remains bound to its originating SDK
lifetime; closing that lifetime seals transport requests. The application retains
immediate regrant. The source correction is commit
`13c3d7e2d939684431b06b8742f24a41be23bc50`, based on upstream 9.24.0.

## Distribution boundary

Only the static **Sentry** product/module is repackaged here, for these targets:

| Platform      | Architectures         |
| ------------- | --------------------- |
| iOS device    | arm64, arm64e         |
| iOS simulator | arm64, x86_64         |
| Mac Catalyst  | arm64, arm64e, x86_64 |

This release is application-scoped, not an all-platform replacement. Other binary
products still reference upstream archives and do not contain the correction.
The three manifests (`Package.swift`, `Package@swift-6.1.swift`, and
`Package@swift-6.2.swift`) point their `Sentry` target at the same corrected archive.
Consumers must pin the final manifest commit; pinning the source-only correction
commit still downloads the upstream binary.

## Artifact and provenance

[Release and build evidence](https://github.com/darktasevski/sentry-cocoa/releases/tag/reader-consent-13c3d7e2d939)

- Source revision: `13c3d7e2d939684431b06b8742f24a41be23bc50`
- Toolchain: Xcode 26.6, build 17F113
- Archive: `Sentry-13c3d7e2d939-f8a2175e6dd9573d.xcframework.zip`
- SHA-256: `f8a2175e6dd9573d36562011f5edea8270788cf4a3600e3c14da47d3abc12884`
- Release assets: `provenance.json` and `build-static-reader.sh`

The script records the Release/static build and validation commands. It applies
the same static framework plist workaround as
`scripts/build-xcframework-slice.sh`. Bit-for-bit rebuild reproducibility is not
claimed. The static distribution is unsigned; SwiftPM verifies the archive
checksum before extraction.

All three platform builds passed. The framework format, architecture, symbol,
and plist validators passed, along with an explicit required-platform and
architecture matrix. The freshly downloaded release archive matched the recorded
checksum, and every extracted file and symlink matched the assembled framework.
These packaging checks do not replace the application's pending-send, immediate
regrant, and restart integration tests.

## Upstream contribution

The ownership and close-seal source correction is separable from these fork
packaging changes. An upstream contribution must be ported to current upstream
main and reviewed and tested by a human under `CONTRIBUTING.md` before submission.
The application stays pinned to the verified fork revision during that process.
