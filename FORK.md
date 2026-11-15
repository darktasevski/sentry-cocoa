# Reader App consent-lifetime distribution

This maintained fork provides the Sentry correction needed by Reader App #2673.
Deferred crash, hang, and breadcrumb work remains bound to its originating SDK
lifetime; closing that lifetime seals transport requests. The application retains
immediate regrant. Cache selection and response transitions share the serial
transport queue, and each flush owns its registration and completion state
(`Sources/Sentry/SentryHttpTransport.m` § `sendAllCachedEnvelopes`, `flush:`,
`completeFlush:`). The source revision is
`70b36b44ca5534622a3ea20e9f63561be546c589`, based on upstream 9.24.0 and retaining
the ownership/close correction `13c3d7e2d939684431b06b8742f24a41be23bc50`.

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
commit still downloads the previous binary.

## Artifact and provenance

[Release and build evidence](https://github.com/darktasevski/sentry-cocoa/releases/tag/reader-consent-70b36b44ca55)

- Source revision: `70b36b44ca5534622a3ea20e9f63561be546c589`
- Toolchain: Xcode 26.6, build 17F113
- Archive: `Sentry-70b36b44ca55-c1ee3aa40f64281b.xcframework.zip`
- SHA-256: `c1ee3aa40f64281b542c0587b10fd59cf5081477ea4571e4fb79c082a6173193`
- Release assets: `provenance.json` and `build-static-reader.sh`

The script records the Release/static build and validation commands. It applies
the same static framework plist workaround as
`scripts/build-xcframework-slice.sh`. Bit-for-bit rebuild reproducibility is not
claimed. The static distribution is unsigned; SwiftPM verifies the archive
checksum before extraction. Builds use `SDK_STAT_CACHE_ENABLE=NO` to avoid the
installed toolchain's stat-cache stall.

All three platform builds passed. The framework format, architecture, symbol,
and plist validators passed, along with an explicit required-platform and
architecture matrix. The freshly downloaded release archive matched the recorded
checksum, and every extracted file and symlink matched the assembled framework.
These packaging checks do not replace the application's pending-send, immediate
regrant, and restart integration tests.

## Upstream contribution

The ownership, close-seal and drain-ordering source corrections are separable
from these fork packaging changes. An upstream contribution must be ported to
current upstream main and reviewed and tested by a human under `CONTRIBUTING.md`
before submission. The application's dependency pin remains a separate decision.
