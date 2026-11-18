@_spi(Private) import Sentry
import XCTest

// The SDK's Test configuration suppresses these fatal calls. Run with test-file-manager-diagnostics.sh.
final class SentryFileManagerDiagnosticsTests: XCTestCase {
    func testInit_whenWorkingDirectoryCreationFails_shouldNotLogCachePath() throws {
        let captured = try captureDirectoryFailure(component: .working)

        XCTAssertTrue(captured.messages.contains { $0.contains("[fatal]") && $0.contains("Failed to create Sentry SDK working directory") })
        XCTAssertFalse(captured.messages.joined().contains(captured.cachePath))
        XCTAssertFalse(captured.messages.joined().contains(captured.grantID))
        XCTAssertEqual(captured.messages.count, 1)
    }

    func testInit_whenEnvelopeDirectoryCreationFails_shouldNotLogCachePath() throws {
        let captured = try captureDirectoryFailure(component: .envelopes)

        XCTAssertTrue(captured.messages.contains { $0.contains("[fatal]") && $0.contains("Failed to create Sentry SDK envelopes directory") })
        XCTAssertFalse(captured.messages.joined().contains(captured.cachePath))
        XCTAssertFalse(captured.messages.joined().contains(captured.grantID))
        XCTAssertEqual(captured.messages.count, 1)
    }

    private enum Component {
        case working
        case envelopes
    }

    private func captureDirectoryFailure(component: Component) throws -> (messages: [String], cachePath: String, grantID: String) {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("seed_file-manager-diagnostics-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try files.removeItem(at: root) }
        let grantID = "00000000-0000-4000-8000-0000000000AB"
        let cache = root.appendingPathComponent(grantID)
        let options = Options()
        options.dsn = "https://public@example.invalid/1"
        options.cacheDirectoryPath = cache.path
        options.debug = false
        SentrySDKLogSupport.configure(false, diagnosticLevel: .none)
        var messages = [String]()
        SentrySDKLog.setOutput { messages.append($0) }
        defer { SentrySDKLog.setOutput(nil) }

        let manager = try makeManager(options: options)
        let working = URL(fileURLWithPath: manager.sentryPath)
        let blocked = component == .working ? working : working.appendingPathComponent("envelopes")
        try files.removeItem(at: blocked)
        try Data([1]).write(to: blocked)

        XCTAssertThrowsError(try makeManager(options: options))
        return (messages, cache.path, grantID)
    }

    private func makeManager(options: Options) throws -> SentryFileManager {
        try SentryFileManager(
            options: options,
            dateProvider: SentryDefaultCurrentDateProvider(),
            dispatchQueueWrapper: SentryDispatchQueueWrapper()
        )
    }
}
