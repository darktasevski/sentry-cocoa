@_spi(Private) import SentryTestUtils
@_spi(Private) @testable import Sentry
import XCTest

final class SentryHangTrackingOwnershipTests: SentrySDKIntegrationTestsBase {
    private struct Fixture {
        let currentDate = TestCurrentDateProvider()
        let dispatchQueueWrapper = TestSentryDispatchQueueWrapper()
        let options: Options

        init() {
            options = Options()
            options.dsn = TestConstants.dsnAsString(username: "SentryHangTrackingOwnershipTests")
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 4.5
            options.releaseName = "owner-release"
        }
    }

    private var fixture: Fixture!
    private var sut: SentryHangTrackingIntegration<SentryDependencyContainer>?

    override var options: Options { fixture.options }

    override func setUp() {
        super.setUp()
        fixture = Fixture()
        SentryDependencyContainer.sharedInstance().dispatchQueueWrapper = fixture.dispatchQueueWrapper
        SentryDependencyContainer.sharedInstance().debugImageProvider = TestDebugImageProvider()
    }

    override func tearDown() {
        sut?.uninstall()
        SentryDependencyContainer.sharedInstance().fileManager = nil
        super.tearDown()
    }

    private func hangTracker(with options: Options) -> SentryHangTrackingIntegration<SentryDependencyContainer>? {
        SentryHangTrackingIntegration(with: options, dependencies: SentryDependencyContainer.sharedInstance())
    }

    private final class EnteredHangFileManager: SentryFileManager {
        var event: Event?
        var onRead: (() -> Void)?

        override func storeAppHang(_ event: Event) {
            self.event = event
        }

        override func readAppHangEvent() -> Event? {
            let callback = onRead
            onRead = nil
            callback?()
            return event
        }

        override func deleteAppHangEvent() {
            event = nil
        }
    }

    private final class EnteredHangThreadInspector: TestThreadInspector {
        var onThreadsRead: (() -> Void)?

        override func getCurrentThreadsWithStackTrace() -> [SentryThread] {
            let callback = onThreadsRead
            onThreadsRead = nil
            callback?()
            return super.getCurrentThreadsWithStackTrace()
        }
    }

    private enum LifetimeHangPath {
        case live, stopped, storedFatal, storedAfterCrash
    }

    #if os(macOS)
    func testNativeHang_whenOwnerClosedDuringEnteredCallback_shouldNotCaptureInReplacement() throws {
        try assertNativeHangOwnership(closeOwner: true)
    }

    func testNativeHang_whenOwnerEligibleAndGlobalHubChanges_shouldCaptureOnOwner() throws {
        try assertNativeHangOwnership(closeOwner: false)
    }

    func testNativeHang_whenOwnerClientClosedButStillBound_shouldDrop() throws {
        try assertNativeHangOwnership(closeOwner: true, unbindOwner: false)
    }

    private func assertNativeHangOwnership(closeOwner: Bool, unbindOwner: Bool = true) throws {
        givenSdkWithHub()
        let owner = SentrySDKInternal.currentHub()
        let ownerClient = try XCTUnwrap(owner.getClient() as? TestClient)
        owner.scope.setTag(value: "owner", key: "lifetime")
        let replacementOptions = Options()
        replacementOptions.dsn = options.dsn
        replacementOptions.enableAppHangTracking = true
        let replacementClient = try XCTUnwrap(TestClient(options: replacementOptions))
        let replacement = SentryHubInternal(client: replacementClient, andScope: Scope())
        replacement.scope.setTag(value: "replacement", key: "lifetime")
        let inspector = EnteredHangThreadInspector(options: options)
        SentryDependencyContainer.sharedInstance().threadInspector = inspector
        SentryDependencyContainer.sharedInstance().fileManager = try TestFileManager(
            options: options,
            dateProvider: fixture.currentDate,
            dispatchQueueWrapper: fixture.dispatchQueueWrapper
        )
        sut = try XCTUnwrap(hangTracker(with: options))
        var entered = false
        inspector.onThreadsRead = {
            entered = true
            if closeOwner {
                owner.close()
                if unbindOwner { owner.bindClient(nil) }
            }
            SentrySDKInternal.setCurrentHub(replacement)
            SentrySDK.setStart(with: replacementOptions)
        }

        sut?.anrDetected(type: .fullyBlocking)

        XCTAssertTrue(entered, "The A callback must enter before the lifetime handoff")
        XCTAssertEqual(replacementClient.captureEventWithScopeInvocations.count, 0, "Entered A hang must never capture through B")
        XCTAssertEqual(ownerClient.captureEventWithScopeInvocations.count, closeOwner ? 0 : 1)
        if !closeOwner {
            XCTAssertEqual(ownerClient.captureEventWithScopeInvocations.first?.scope.tags["lifetime"], "owner")
        } else if unbindOwner {
            XCTAssertNil(owner.getClient())
        } else {
            XCTAssertIdentical(owner.getClient(), ownerClient, "The closed A client must remain bound for this case")
        }

        sut?.uninstall()
        sut = try XCTUnwrap(hangTracker(with: replacementOptions))
        sut?.anrDetected(type: .fullyBlocking)

        XCTAssertEqual(replacementClient.captureEventWithScopeInvocations.count, 1, "Fresh B hang producer must remain enabled")
        XCTAssertEqual(replacementClient.captureEventWithScopeInvocations.first?.scope.tags["lifetime"], "replacement")
        XCTAssertEqual(ownerClient.captureEventWithScopeInvocations.count, closeOwner ? 0 : 1, "Fresh B hang must not capture through A")
    }
    #endif

    #if os(iOS) || os(tvOS)
    func testLiveHang_whenOwnerClosedDuringEnteredCallback_shouldNotStoreReplacementScope() throws {
        try assertHangOwnership(path: .live, closeOwner: true)
    }

    func testLiveHang_whenOwnerEligibleAndGlobalHubChanges_shouldUseOwnerScope() throws {
        try assertHangOwnership(path: .live, closeOwner: false)
    }

    func testStoppedHang_whenOwnerClosedDuringEnteredCallback_shouldNotCaptureInReplacement() throws {
        try assertHangOwnership(path: .stopped, closeOwner: true)
    }

    func testStoppedHang_whenOwnerEligibleAndGlobalHubChanges_shouldCaptureOnOwner() throws {
        try assertHangOwnership(path: .stopped, closeOwner: false)
    }

    func testLiveHang_whenOwnerClientClosedButStillBound_shouldDrop() throws {
        try assertHangOwnership(path: .live, closeOwner: true, unbindOwner: false)
    }

    func testStoppedHang_whenOwnerClientClosedButStillBound_shouldDrop() throws {
        try assertHangOwnership(path: .stopped, closeOwner: true, unbindOwner: false)
    }

    func testStoredFatalHang_whenOwnerClosedDuringEnteredCallback_shouldNotCaptureInReplacement() throws {
        try assertHangOwnership(path: .storedFatal, closeOwner: true)
    }

    func testStoredFatalHang_whenOwnerEligibleAndGlobalHubChanges_shouldCaptureOnOwner() throws {
        try assertHangOwnership(path: .storedFatal, closeOwner: false)
    }

    func testStoredHangAfterCrash_whenOwnerClosedDuringEnteredCallback_shouldNotCaptureInReplacement() throws {
        try assertHangOwnership(path: .storedAfterCrash, closeOwner: true)
    }

    func testStoredHangAfterCrash_whenOwnerEligibleAndGlobalHubChanges_shouldCaptureOnOwner() throws {
        try assertHangOwnership(path: .storedAfterCrash, closeOwner: false)
    }

    func testStoredFatalHang_whenOwnerClientClosedButStillBound_shouldDrop() throws {
        try assertHangOwnership(path: .storedFatal, closeOwner: true, unbindOwner: false)
    }

    func testStoredHangAfterCrash_whenOwnerClientClosedButStillBound_shouldDrop() throws {
        try assertHangOwnership(path: .storedAfterCrash, closeOwner: true, unbindOwner: false)
    }

    private func assertHangOwnership(path: LifetimeHangPath, closeOwner: Bool, unbindOwner: Bool = true) throws {
        givenSdkWithHub()
        let owner = SentrySDKInternal.currentHub()
        let ownerClient = try XCTUnwrap(owner.getClient() as? TestClient)
        owner.scope.setTag(value: "owner", key: "lifetime")
        let replacementOptions = Options()
        replacementOptions.dsn = options.dsn
        replacementOptions.releaseName = "replacement-release"
        replacementOptions.enableAppHangTracking = true
        let replacementClient = try XCTUnwrap(TestClient(options: replacementOptions))
        let replacement = SentryHubInternal(client: replacementClient, andScope: Scope())
        replacement.scope.setTag(value: "replacement", key: "lifetime")
        let manager = EnteredHangFileManager(
            helper: try SentryFileManagerHelper(options: options),
            dateProvider: fixture.currentDate,
            dispatchQueueWrapper: fixture.dispatchQueueWrapper
        )
        let inspector = EnteredHangThreadInspector(options: options)
        SentryDependencyContainer.sharedInstance().fileManager = manager
        SentryDependencyContainer.sharedInstance().threadInspector = inspector
        crashWrapper.internalCrashedLastLaunch = path == .storedAfterCrash
        var entered = false
        let handoff = {
            entered = true
            if closeOwner {
                owner.close()
                if unbindOwner { owner.bindClient(nil) }
            }
            SentrySDKInternal.setCurrentHub(replacement)
            SentrySDK.setStart(with: replacementOptions)
        }

        switch path {
        case .live, .stopped:
            sut = try XCTUnwrap(hangTracker(with: options))
            if path == .live {
                inspector.onThreadsRead = handoff
                sut?.anrDetected(type: .fullyBlocking)
            } else {
                sut?.anrDetected(type: .fullyBlocking)
                manager.onRead = handoff
                sut?.anrStopped(result: SentryANRStoppedResult(minDuration: 1, maxDuration: 2))
            }
        case .storedFatal, .storedAfterCrash:
            let event = Event(level: .error)
            let exception = Exception(value: "fixture hang", type: "App Hang Fully Blocked")
            let mechanism = Mechanism(type: "AppHang")
            mechanism.data = ["app_hang_duration": "at least 4500 ms"]
            exception.mechanism = mechanism
            event.exceptions = [exception]
            event.tags = ["lifetime": "owner"]
            manager.event = event
            manager.onRead = handoff
            sut = try XCTUnwrap(hangTracker(with: options))
        }

        XCTAssertTrue(entered, "The A hang callback must enter before the lifetime handoff")
        XCTAssertEqual(replacementClient.captureEventWithScopeInvocations.count, 0, "Entered A hang must never capture through B")
        XCTAssertEqual(replacementClient.captureFatalEventInvocations.count, 0, "Entered A fatal hang must never capture through B")
        if path == .live {
            XCTAssertEqual(manager.event?.tags?["lifetime"], closeOwner ? nil : "owner", "Live A hang must never read B scope")
            XCTAssertEqual(manager.event?.releaseName, closeOwner ? nil : "owner-release", "Live A hang must use installation options after B starts")
        } else if path == .storedFatal {
            XCTAssertEqual(ownerClient.captureFatalEventInvocations.count, closeOwner ? 0 : 1)
            if !closeOwner {
                XCTAssertEqual(ownerClient.captureFatalEventInvocations.first?.scope.tags["lifetime"], "owner")
            }
        } else {
            XCTAssertEqual(ownerClient.captureEventWithScopeInvocations.count, closeOwner ? 0 : 1)
            if !closeOwner {
                XCTAssertEqual(ownerClient.captureEventWithScopeInvocations.first?.event.tags?["lifetime"], "owner")
            }
        }

        sut?.uninstall()
        manager.deleteAppHangEvent()
        sut = try XCTUnwrap(hangTracker(with: replacementOptions))
        sut?.anrDetected(type: .fullyBlocking)
        XCTAssertEqual(manager.event?.tags?["lifetime"], "replacement", "Fresh B live hang must use B scope")
        XCTAssertEqual(manager.event?.releaseName, "replacement-release", "Fresh B producer must use B installation options")
        sut?.anrStopped(result: SentryANRStoppedResult(minDuration: 1, maxDuration: 2))
        XCTAssertEqual(replacementClient.captureEventWithScopeInvocations.count, 1, "Fresh B hang producer must remain enabled")
    }
    #endif

}
