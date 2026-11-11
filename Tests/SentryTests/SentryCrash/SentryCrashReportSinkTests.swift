@_spi(Private) import Sentry
@_spi(Private) @testable import SentryTestUtils
import XCTest

class SentryCrashReportSinkTests: SentrySDKIntegrationTestsBase {

    private final class EnteredCrashReporter: TestSentryCrashReporter {
        var onDurationRead: (() -> Void)?

        override var durationFromCrashStateInitToLastCrash: TimeInterval {
            let callback = onDurationRead
            onDurationRead = nil
            callback?()
            return super.durationFromCrashStateInitToLastCrash
        }
    }
    
    private class Fixture {
        let crashWrapper = TestSentryCrashWrapper(processInfoWrapper: ProcessInfo.processInfo)
        let dispatchQueue = TestSentryDispatchQueueWrapper()
        
        var sut: SentryCrashReportSink {
            return SentryCrashReportSink(inAppLogic: SentryInAppLogic(inAppIncludes: []), crashWrapper: crashWrapper, dispatchQueue: dispatchQueue)
        }
    }
    
    private var fixture: Fixture!
    
    override func setUp() {
        super.setUp()
        fixture = Fixture()
        
        givenSdkWithHub()
    }
    
    override func tearDown() {
        super.tearDown()
        clearTestState()
    }
        
    func testFilterReports_withScreenShots() {
        filterReportWithAttachment()
        XCTAssertEqual(1, fixture.dispatchQueue.dispatchAsyncCalled)
    }

    func testFilterReports_whenOwnerClosedDuringEnteredReplay_shouldNotCaptureInReplacement() throws {
        try assertReplayOwnership(startup: false, closeOwner: true)
    }

    func testFilterReports_whenOwnerEligibleAndGlobalHubChanges_shouldCaptureOnOwner() throws {
        try assertReplayOwnership(startup: false, closeOwner: false)
    }

    func testFilterReports_whenOwnerClientClosedButStillBound_shouldDrop() throws {
        try assertReplayOwnership(startup: false, closeOwner: true, unbindOwner: false)
    }

    func testStartupReplay_whenOwnerClosedDuringEnteredCallback_shouldNotCaptureOrFlushReplacement() throws {
        try assertReplayOwnership(startup: true, closeOwner: true)
    }

    func testStartupReplay_whenOwnerEligibleAndGlobalHubChanges_shouldCaptureAndFlushOwner() throws {
        try assertReplayOwnership(startup: true, closeOwner: false)
    }

    private func assertReplayOwnership(startup: Bool, closeOwner: Bool, unbindOwner: Bool = true) throws {
        let owner = SentrySDKInternal.currentHub()
        let ownerClient = try XCTUnwrap(owner.getClient() as? TestClient)
        owner.scope.setTag(value: "owner", key: "lifetime")
        let replacementClient = try XCTUnwrap(TestClient(options: options))
        let replacement = SentryHubInternal(client: replacementClient, andScope: Scope())
        replacement.scope.setTag(value: "replacement", key: "lifetime")
        let reporter = EnteredCrashReporter()
        reporter.internalDurationFromCrashStateInitToLastCrash = startup ? 1 : 0
        let sink = SentryCrashReportSink(inAppLogic: SentryInAppLogic(inAppIncludes: []), crashWrapper: reporter, dispatchQueue: fixture.dispatchQueue)
        var entered = false
        reporter.onDurationRead = {
            entered = true
            if closeOwner {
                owner.close()
                if unbindOwner { owner.bindClient(nil) }
            }
            SentrySDKInternal.setCurrentHub(replacement)
        }

        sink.filterReports([[:]]) { _, _, _ in }

        XCTAssertTrue(entered, "The A replay callback must enter before the lifetime handoff")
        XCTAssertEqual(replacementClient.captureFatalEventInvocations.count, 0, "Entered A replay must never capture through B")
        XCTAssertEqual(replacementClient.flushInvocations.count, 0, "Startup replay must never flush B")
        XCTAssertEqual(ownerClient.captureFatalEventInvocations.count, closeOwner ? 0 : 1)
        if !closeOwner {
            XCTAssertEqual(ownerClient.captureFatalEventInvocations.first?.scope.tags["lifetime"], "owner")
            XCTAssertEqual(ownerClient.flushInvocations.count, startup ? 1 : 0)
        }

        let freshSink = fixture.sut
        freshSink.filterReports([[:]]) { _, _, _ in }
        XCTAssertEqual(replacementClient.captureFatalEventInvocations.count, 1, "Fresh B crash replay must remain enabled")
        XCTAssertEqual(replacementClient.captureFatalEventInvocations.first?.scope.tags["lifetime"], "replacement")
    }
    
    func testFilterReports_CopyHubScope() {
        SentrySDKInternal.currentHub().scope.setEnvironment("testFilterReports_CopyHubScope")
        
        let expect = expectation(description: "Callback Called")
        
        let report = [String: Any]()
        
        let reportSink = fixture.sut
        reportSink.filterReports([report]) { _, _, _ in
            self.assertFatalEventWithScope { _, scope in
                let data = scope?.serialize()
                XCTAssertEqual(data?["environment"] as? String, "testFilterReports_CopyHubScope")
                expect.fulfill()
            }
        }
                
        wait(for: [expect], timeout: 1)
        
        XCTAssertEqual(1, fixture.dispatchQueue.dispatchAsyncCalled)
    }
    
    func testAppStartCrash_LowerBound_CallsFlush() throws {
        fixture.crashWrapper.internalDurationFromCrashStateInitToLastCrash = 0.001
        
        filterReportWithAttachment()
        
        let client = getTestClient()
        XCTAssertEqual(1, client.flushInvocations.count)
        XCTAssertEqual(try XCTUnwrap(client.flushInvocations.first), 5, accuracy: 0.001)
        XCTAssertEqual(0, fixture.dispatchQueue.dispatchAsyncCalled)
    }
    
    func testAppStartCrash_LowerBound_SetsDetectedStartUpCrash() {
        fixture.crashWrapper.internalDurationFromCrashStateInitToLastCrash = 0.001
        
        filterReportWithAttachment()
        
        XCTAssertEqual(SentrySDK.detectedStartUpCrash, true)
    }
    
    func testAppStartCrash_UpperBound_CallsFlush() throws {
        fixture.crashWrapper.internalDurationFromCrashStateInitToLastCrash = 2.0
        
        filterReportWithAttachment()
        
        let client = getTestClient()
        XCTAssertEqual(1, client.flushInvocations.count)
        XCTAssertEqual(try XCTUnwrap(client.flushInvocations.first), 5, accuracy: 0.001)
        XCTAssertEqual(0, fixture.dispatchQueue.dispatchAsyncCalled)
    }
    
    func testAppStartCrash_DurationTooSmall_DoesNotCallFlush() {
        fixture.crashWrapper.internalDurationFromCrashStateInitToLastCrash = 0
        
        filterReportWithAttachment()
        
        let client = getTestClient()
        XCTAssertEqual(0, client.flushInvocations.count)
        XCTAssertEqual(1, fixture.dispatchQueue.dispatchAsyncCalled)
    }
    
    func testAppStartCrash_DurationNegative_DoesNotCallFlush() {
        fixture.crashWrapper.internalDurationFromCrashStateInitToLastCrash = -0.001
        
        filterReportWithAttachment()
        
        let client = getTestClient()
        XCTAssertEqual(0, client.flushInvocations.count)
        XCTAssertEqual(1, fixture.dispatchQueue.dispatchAsyncCalled)
    }
    
    func testAppStartCrash_DurationTooBig_DoesNotCallFlush() {
        fixture.crashWrapper.internalDurationFromCrashStateInitToLastCrash = 2.00001
        
        filterReportWithAttachment()
        
        let client = getTestClient()
        XCTAssertEqual(0, client.flushInvocations.count)
        XCTAssertEqual(1, fixture.dispatchQueue.dispatchAsyncCalled)
    }
    
    private func filterReportWithAttachment() {
        let report = ["attachments": ["file.png"]]
        fixture.sut.filterReports([report]) { _, _, _ in
            self.assertFatalEventWithScope { _, scope in
                XCTAssertEqual(scope?.attachments.count, 1)
            }
        }
    }
    
    private func getTestClient() -> TestClient {
        let client = SentrySDKInternal.currentHub().getClient() as? TestClient
        
        if client == nil {
            XCTFail("Hub Client is not a `TestClient`")
        }
        
        return client!
    }
}
