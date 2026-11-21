# Reader App fork extensions (`fork-extensions` branch)

This maintained fork carries the Sentry corrections Reader App needs, on top of
upstream release 9.24.0.

## Branches

- `fork-extensions` is the source of truth: the long-lived integration branch that
  holds every fork change. Reader App pins a commit on it.
- `main` mirrors upstream `main` and carries no fork changes.
- Work branches start from `fork-extensions` and merge back into it. An upstream
  release is merged into `fork-extensions`, never into a work branch.
- Earlier work branches (`refactor/2673-consent-lifetime`,
  `fix/hardened-mach-exceptions`) and the `reader-consent-*` tags stay, because
  older Reader App pins point at their commits.

## Inventory

| Commit                     | Change                                                                                                                                                                                                                                                                                                                                                                                                | Kind       |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| `13c3d7e2d939`             | Deferred crash, watchdog, hang and breadcrumb work stays bound to its originating SDK lifetime; closing that lifetime seals transport requests (`Sources/Sentry/SentryCrashReportSink.m`, `SentryQueueableRequestManager.m`)                                                                                                                                                                          | source fix |
| `70b36b44ca55`             | Cache selection and response transitions share the serial transport queue; each flush owns its registration and completion state (`Sources/Sentry/SentryHttpTransport.m` § `sendAllCachedEnvelopes`, `flush:`, `completeFlush:`)                                                                                                                                                                      | source fix |
| `2795d9a5e9fd`             | Directory-initialization failure messages omit the cache path and its consent namespace (`Sources/Sentry/SentryFileManagerHelper.m`)                                                                                                                                                                                                                                                                  | source fix |
| `c8f1ab52085f`             | The Mach exception monitor registers with `EXCEPTION_IDENTITY_PROTECTED`, falling back to `EXCEPTION_DEFAULT` where the system rejects it (Rosetta), so a process signed with Enhanced Security `platform-restrictions-string` = 2 is not killed with `EXC_GUARD` (`Sources/SentryCrash/Recording/Monitors/SentryCrashMonitor_MachException.c`). Proven by `scripts/test-hardened-mach-exceptions.sh` | source fix |
| `2612a86cb9`, `23950a0d01` | Point the binary `Sentry` target at the fork's static archive                                                                                                                                                                                                                                                                                                                                         | packaging  |
| `81b60242d2`               | Empty commit verifying commit signing                                                                                                                                                                                                                                                                                                                                                                 | plumbing   |

Reader App links the source-built `SentrySPM` product, so it gets every source fix
at its pinned commit. The binary `Sentry` archive described below was built at
`70b36b44ca55` and predates `2795d9a5e9fd` and `c8f1ab52085f`: a consumer of the
binary product does not get those two fixes until the archive is rebuilt.

# Binary `Sentry` distribution

The archive is built from source revision
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

# Upstream contribution

The four source fixes in the inventory are separable from the fork packaging
changes. An upstream contribution must be ported to
current upstream main and reviewed and tested by a human under `CONTRIBUTING.md`
before submission. The application's dependency pin remains a separate decision.
