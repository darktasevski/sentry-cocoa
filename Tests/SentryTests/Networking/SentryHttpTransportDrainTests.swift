@_spi(Private) import SentryTestUtils
@_spi(Private) @testable import Sentry
import XCTest

final class SentryHttpTransportDrainTests: XCTestCase {
    func testSend_whenCaptureArrivesAfterEmptySnapshot_shouldDrainWithoutAnotherWake() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()

        fixture.files.afterEmptySnapshot = {
            (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
            fixture.queue.runReadyIfIdle()
        }

        // -- Act --
        fixture.reachability.triggerNetworkReachable()
        fixture.queue.runReady()

        // -- Assert --
        XCTAssertEqual(fixture.requests.count, 1, "D1: a capture must retain its only drain opportunity")
    }

    func testInit_whenCacheContainsEnvelope_shouldScheduleStartupDrain() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        _ = fixture.files.store(SentryEnvelope(event: Event()))

        // -- Act --
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()

        // -- Assert --
        XCTAssertEqual(fixture.requests.count, 1, "D2: startup must request cached delivery")
        withExtendedLifetime(transport) { }
    }

    func testSend_whenNoOtherTrigger_shouldRequestDrainAfterStore() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()

        // -- Act --
        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
        fixture.queue.runReady()

        // -- Assert --
        XCTAssertEqual(fixture.requests.count, 1, "D3: storage must request delivery")
    }

    func testSend_whenSuccessArrivesWithAnotherEnvelopeCached_shouldContinueAfterDelay() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()
        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
        fixture.queue.runReady()
        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
        fixture.queue.runReady()
        XCTAssertEqual(fixture.requests.count, 1)

        // -- Act --
        fixture.requests.completeNext(response: DrainFixture.okResponse)
        fixture.queue.runReady()
        XCTAssertEqual(fixture.requests.count, 1, "Configured delay is a separately controlled opportunity")
        fixture.queue.releaseDelayed()
        fixture.queue.runReady()

        // -- Assert --
        XCTAssertEqual(fixture.requests.count, 2, "D4: success must continue cached delivery")
    }

    func testResponse_whenCallbackArrivesOutsideQueue_shouldDeferDrainStateChanges() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()
        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
        fixture.queue.runReady()

        // -- Act --
        fixture.requests.completeNext(response: DrainFixture.okResponse)

        // -- Assert --
        XCTAssertEqual(fixture.files.getAllEnvelopes().count, 1, "D5: response must not delete outside the HTTP queue")
        XCTAssertEqual(fixture.queue.delayedCount, 0, "D5: response must not schedule continuation outside the HTTP queue")
        fixture.queue.runReady()
        XCTAssertEqual(fixture.files.getAllEnvelopes().count, 0)
        XCTAssertEqual(fixture.queue.delayedCount, 1)
    }

    func testResponse_whenMissing_shouldRetainEnvelopeUntilExplicitRecovery() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()
        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
        fixture.queue.runReady()

        // -- Act --
        fixture.requests.completeNext(response: nil)
        fixture.queue.runReady()
        fixture.queue.releaseDelayed()
        fixture.queue.runReady()

        // -- Assert --
        XCTAssertEqual(fixture.requests.count, 1, "D6: missing response must not create an automatic retry loop")
        XCTAssertEqual(fixture.files.getAllEnvelopes().count, 1, "D6: missing response must retain cached work")
        fixture.reachability.triggerNetworkReachable()
        fixture.queue.runReady()
        XCTAssertEqual(fixture.requests.count, 2, "D6: explicit recovery must permit retry")
    }

    func testFlush_whenStartupPrecedesCaptureAndActivation_shouldRemainPendingUntilActivated() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
        let call = beginFlush(fixture, transport: transport)
        let registered = try XCTUnwrap(fixture.flushes.snapshot(at: 0))
        XCTAssertFalse(registered.activated)
        XCTAssertFalse(registered.terminal)

        // -- Act --
        XCTAssertTrue(fixture.queue.runOne())

        // -- Assert --
        let afterStartup = try XCTUnwrap(fixture.flushes.snapshot(at: 0))
        XCTAssertFalse(afterStartup.activated)
        XCTAssertFalse(afterStartup.terminal, "F1: earlier empty startup cannot finish a merely registered flush")
        guard !afterStartup.terminal else {
            wait(for: [call.returned], timeout: 5)
            return
        }
        XCTAssertTrue(fixture.queue.runOne())
        XCTAssertTrue(fixture.queue.runOne())
        let activated = try XCTUnwrap(fixture.flushes.snapshot(at: 0))
        XCTAssertTrue(activated.activated)
        XCTAssertFalse(activated.terminal, "F1: activation cannot finish while its response is held")
        XCTAssertEqual(fixture.requests.count, 1)

        fixture.requests.completeNext(response: DrainFixture.okResponse)
        fixture.queue.runReady()
        fixture.queue.releaseDelayed()
        fixture.queue.runReady()
        wait(for: [call.returned], timeout: 5)
        XCTAssertEqual(call.result, .success, "F1: activated flush must finish after successful drain")
    }

    func testFlush_whenQueueHeldAcrossTimeouts_shouldCleanUpImmediatelyAndIgnoreStaleActivations() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()

        // -- Act --
        XCTAssertEqual((transport as Transport).flush(0), .timedOut)
        // -- Assert --
        XCTAssertEqual((transport as Transport).flush(0), .timedOut, "F2: timeout cleanup must release registration without queue progress")
        XCTAssertEqual(fixture.flushes.count, 2)
        XCTAssertTrue(try XCTUnwrap(fixture.flushes.snapshot(at: 0)).terminal)
        XCTAssertTrue(try XCTUnwrap(fixture.flushes.snapshot(at: 1)).terminal)

        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
        let call = beginFlush(fixture, transport: transport)
        let successor = try XCTUnwrap(fixture.flushes.snapshot(at: 2))
        for _ in 0..<2 {
            XCTAssertTrue(fixture.queue.runOne())
            let observed = try XCTUnwrap(fixture.flushes.snapshot(at: 2))
            XCTAssertIdentical(observed.identity, successor.identity)
            XCTAssertFalse(observed.activated, "F3: stale activation cannot activate the successor")
            XCTAssertFalse(observed.terminal, "F3: stale activation cannot complete the successor")
            guard !observed.terminal else {
                wait(for: [call.returned], timeout: 5)
                return
            }
        }
        XCTAssertTrue(fixture.queue.runOne())
        XCTAssertTrue(fixture.queue.runOne())
        XCTAssertTrue(try XCTUnwrap(fixture.flushes.snapshot(at: 2)).activated)
        XCTAssertFalse(try XCTUnwrap(fixture.flushes.snapshot(at: 2)).terminal)

        fixture.requests.completeNext(response: DrainFixture.okResponse)
        fixture.queue.runReady()
        fixture.queue.releaseDelayed()
        fixture.queue.runReady()
        wait(for: [call.returned], timeout: 5)
        XCTAssertEqual(call.result, .success, "F3: a successor must recover and finish with balanced completion")
    }

    func testFlush_whenZeroTimeoutExpires_shouldPreserveItsQueuedDrainOpportunity() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()
        _ = fixture.files.store(SentryEnvelope(event: Event()))

        // -- Act --
        XCTAssertEqual((transport as Transport).flush(0), .timedOut)
        fixture.queue.runReady()

        // -- Assert --
        XCTAssertEqual(fixture.requests.count, 1, "F4: terminal wait must not discard its accepted drain wake")
    }

    func testFlush_whenOldSuccessfulCallerCleansUp_shouldPreserveSuccessorRegistration() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()
        let paused = expectation(description: "First successful waiter reached caller cleanup")
        let resume = XCTestExpectation(description: "Release first caller cleanup")
        let pauseOnce = SentryMutex(false)
        fixture.flushes.cleanup = { _, result in
            let shouldPause = pauseOnce.withLock { paused in
                if paused || result != 0 { return false }
                paused = true
                return true
            }
            if shouldPause {
                paused.fulfill()
                XCTAssertEqual(XCTWaiter.wait(for: [resume], timeout: 5), .completed)
            }
        }
        let first = beginFlush(fixture, transport: transport)
        fixture.queue.runReady()
        wait(for: [paused], timeout: 5)
        let second = beginFlush(fixture, transport: transport)
        let successor = try XCTUnwrap(fixture.flushes.snapshot(at: 1))

        // -- Act --
        resume.fulfill()
        wait(for: [first.returned], timeout: 5)

        // -- Assert --
        let afterCleanup = try XCTUnwrap(fixture.flushes.snapshot(at: 1))
        XCTAssertIdentical(afterCleanup.identity, successor.identity)
        XCTAssertFalse(afterCleanup.activated)
        XCTAssertFalse(afterCleanup.terminal, "F5: old caller cleanup cannot finish the successor")
        fixture.queue.runReady()
        wait(for: [second.returned], timeout: 5)
        XCTAssertEqual(first.result, .success)
        XCTAssertEqual(second.result, .success)
    }

    func testFlush_whenActivatedRequestIsHeld_shouldExcludeConcurrentCallAndFinishOnce() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let transport = try fixture.makeTransport()
        fixture.queue.runReady()
        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
        fixture.queue.runReady()
        let call = beginFlush(fixture, transport: transport)
        fixture.queue.runReady()
        let beforeConcurrent = try XCTUnwrap(fixture.flushes.snapshot(at: 0))
        XCTAssertTrue(beforeConcurrent.activated)
        XCTAssertFalse(beforeConcurrent.terminal)

        // -- Act --
        XCTAssertEqual((transport as Transport).flush(0), .alreadyFlushing, "F6: concurrent registration must be rejected")
        // -- Assert --
        XCTAssertEqual(fixture.flushes.count, 1)
        XCTAssertFalse(try XCTUnwrap(fixture.flushes.snapshot(at: 0)).terminal)
        fixture.requests.completeNext(response: DrainFixture.okResponse)
        fixture.queue.runReady()
        fixture.queue.releaseDelayed()
        fixture.queue.runReady()

        wait(for: [call.returned], timeout: 5)
        XCTAssertEqual(call.result, .success, "F6: activated flush must leave its own wait group")
        XCTAssertTrue(try XCTUnwrap(fixture.flushes.snapshot(at: 0)).terminal)
    }

    func testClose_whenHTTPQueueIsHeld_shouldSealRealManagerBeforeReturning() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let session = CloseSealRecordingSession()
        defer { session.invalidateAndCancel() }
        let manager = SentryQueueableRequestManager(session: session)
        _ = fixture.files.store(SentryEnvelope(event: Event()))
        let transport = try fixture.makeTransport(requestManager: manager)
        defer { withExtendedLifetime(transport) { } }
        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))

        // -- Act --
        (transport as Transport).close()
        session.markCloseReturned()
        (transport as Transport).send(envelope: SentryEnvelope(event: Event()))
        fixture.queue.runReady()
        fixture.queue.releaseDelayed()
        fixture.queue.runReady()

        // -- Assert --
        XCTAssertEqual(session.recordedTasks.count, 0, "C1: transport close must seal admission before held work can create a task")
        XCTAssertEqual(session.recordedTasksCreatedAfterClose.count, 0)
    }

    func testClose_whenSuccessorStartsWithOldQueueHeld_shouldKeepTransportsIndependent() throws {
        // -- Arrange --
        let old = try DrainFixture()
        old.queue.hold()
        let successor = try DrainFixture()
        defer {
            old.cleanUp()
            successor.cleanUp()
        }
        let session = CloseSealRecordingSession()
        defer { session.invalidateAndCancel() }
        let manager = SentryQueueableRequestManager(session: session)
        _ = old.files.store(SentryEnvelope(event: Event()))
        let oldTransport = try old.makeTransport(requestManager: manager)
        defer { withExtendedLifetime(oldTransport) { } }
        (oldTransport as Transport).close()
        session.markCloseReturned()

        // -- Act --
        let newTransport = try successor.makeTransport()
        defer { withExtendedLifetime(newTransport) { } }
        (newTransport as Transport).send(envelope: SentryEnvelope(event: Event()))
        successor.queue.runReady()
        // -- Assert --
        XCTAssertEqual(successor.requests.count, 1, "C2: successor must send without releasing its predecessor's queue")
        successor.requests.completeNext(response: DrainFixture.okResponse)
        successor.queue.runReady()
        successor.queue.releaseDelayed()
        successor.queue.runReady()
        XCTAssertEqual(successor.files.getAllEnvelopes().count, 0, "C2: successor delivery must complete independently")

        old.queue.resume()
        old.queue.runReady()
        old.queue.releaseDelayed()
        old.queue.runReady()
        XCTAssertEqual(session.recordedTasks.count, 0, "C2: old queued work must remain bound to its sealed manager")
        XCTAssertEqual(successor.requests.count, 1)
    }

    func testFixture_whenSuccessorUsesHeldPredecessorQueue_shouldExposeBlockedDelivery() throws {
        // -- Arrange --
        let old = try DrainFixture()
        old.queue.hold()
        let successor = try DrainFixture(queue: old.queue)
        defer {
            old.cleanUp()
            successor.cleanUp()
        }
        let oldTransport = try old.makeTransport()
        defer { withExtendedLifetime(oldTransport) { } }
        (oldTransport as Transport).close()
        // -- Act --
        let newTransport = try successor.makeTransport()
        defer { withExtendedLifetime(newTransport) { } }
        (newTransport as Transport).send(envelope: SentryEnvelope(event: Event()))
        successor.queue.runReady()

        // -- Assert --
        XCTAssertEqual(successor.requests.count, 0)
        XCTAssertNotEqual(successor.requests.count, 1, "C2 control: a shared held queue must fail independent admission")
        old.queue.resume()
        old.queue.runReady()
        XCTAssertEqual(successor.requests.count, 1)
    }

    func testFixture_whenOldTransportUsesReplacementManager_shouldExposeLateTaskConstruction() throws {
        // -- Arrange --
        let fixture = try DrainFixture()
        defer { fixture.cleanUp() }
        let originalSession = CloseSealRecordingSession()
        let replacementSession = CloseSealRecordingSession()
        defer {
            originalSession.invalidateAndCancel()
            replacementSession.invalidateAndCancel()
        }
        let originalManager = SentryQueueableRequestManager(session: originalSession)
        let replacementManager = SentryQueueableRequestManager(session: replacementSession)
        _ = fixture.files.store(SentryEnvelope(event: Event()))
        let transport = try fixture.makeTransport(requestManager: originalManager)
        (transport as Transport).close()
        originalSession.markCloseReturned()
        replacementSession.markCloseReturned()

        // -- Act --
        transport.setValue(replacementManager, forKey: "requestManager")
        fixture.queue.runReady()

        // -- Assert --
        XCTAssertEqual(originalSession.recordedTasks.count, 0)
        XCTAssertEqual(replacementSession.recordedTasksCreatedAfterClose.count, 1)
        XCTAssertNotEqual(replacementSession.recordedTasksCreatedAfterClose.count, 0,
                          "C2 control: rebinding old work must fail the no-late-task condition")
        (transport as Transport).close()
    }

    private func beginFlush(_ fixture: DrainFixture, transport: SentryHttpTransport) -> DrainFlushCall {
        let enqueued = expectation(description: "Flush activation enqueued after acknowledged registration")
        fixture.queue.acknowledgeNextEnqueue { enqueued.fulfill() }
        let call = DrainFlushCall(transport: transport as Transport)
        wait(for: [enqueued], timeout: 5)
        return call
    }

    func testQueue_whenNestedWorkIsEnqueued_shouldPreserveFIFOAndNonreentrancy() {
        // -- Arrange --
        let queue = DrainQueue()
        let events = SentryMutex<[Int]>([])
        // -- Act --
        queue.dispatchAsync {
            events.withLock { $0.append(1) }
            queue.dispatchAsync { events.withLock { $0.append(3) } }
            queue.runReadyIfIdle()
            events.withLock { $0.append(2) }
        }
        // -- Assert --
        XCTAssertEqual(events.withLock { $0 }, [])
        queue.runReady()
        XCTAssertEqual(events.withLock { $0 }, [1, 2, 3])
    }

    func testQueue_whenDelayedWorkExists_shouldRequireExplicitRelease() {
        // -- Arrange --
        let queue = DrainQueue()
        let calls = SentryMutex(0)
        // -- Act --
        queue.dispatch(after: 0) { calls.withLock { $0 += 1 } }
        queue.runReady()
        // -- Assert --
        XCTAssertEqual(calls.withLock { $0 }, 0)
        queue.releaseDelayed()
        queue.runReady()
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testQueue_whenInlineControlIsUsed_shouldDetectBrokenFIFOContract() {
        // -- Arrange --
        let queue = TestSentryDispatchQueueWrapper()
        let events = SentryMutex<[Int]>([])
        // -- Act --
        queue.dispatchAsync {
            events.withLock { $0.append(1) }
            queue.dispatchAsync { events.withLock { $0.append(3) } }
            events.withLock { $0.append(2) }
        }
        // -- Assert --
        XCTAssertEqual(events.withLock { $0 }, [1, 3, 2])
        XCTAssertNotEqual(events.withLock { $0 }, [1, 2, 3], "The inline control must fail the serial FIFO contract")
    }

    func testQueue_whenRealSerialQueueIsUsed_shouldMatchFIFOContract() {
        // -- Arrange --
        let queue = SentryDispatchQueueWrapper(name: "SentryHttpTransportDrainTests.serial")
        let finished = expectation(description: "Nested FIFO work")
        let events = SentryMutex<[Int]>([])
        // -- Act --
        queue.dispatchAsync {
            events.withLock { $0.append(1) }
            queue.dispatchAsync {
                events.withLock { $0.append(3) }
                finished.fulfill()
            }
            events.withLock { $0.append(2) }
        }
        wait(for: [finished], timeout: 5)
        // -- Assert --
        XCTAssertEqual(events.withLock { $0 }, [1, 2, 3])
    }
}

private final class DrainQueue: SentryDispatchQueueWrapper {
    private struct State {
        var ready: [() -> Void] = []
        var delayed: [() -> Void] = []
        var executing = false
        var held = false
        var nextEnqueue: (() -> Void)?
    }
    private let state = SentryMutex(State())

    var delayedCount: Int { state.withLock { $0.delayed.count } }

    override func dispatchAsync(_ block: @escaping () -> Void) {
        let acknowledged = state.withLock { state in
            state.ready.append(block)
            let callback = state.nextEnqueue
            state.nextEnqueue = nil
            return callback
        }
        acknowledged?()
    }

    func acknowledgeNextEnqueue(_ callback: @escaping () -> Void) {
        state.withLock { $0.nextEnqueue = callback }
    }

    func hold() { state.withLock { $0.held = true } }

    func resume() { state.withLock { $0.held = false } }

    override func dispatch(after interval: TimeInterval, block: @escaping () -> Void) {
        state.withLock { $0.delayed.append(block) }
    }

    @discardableResult
    func runOne() -> Bool {
        let block: (() -> Void)? = state.withLock {
            guard !$0.executing, !$0.held, !$0.ready.isEmpty else { return nil }
            $0.executing = true
            return $0.ready.removeFirst()
        }
        guard let block else { return false }
        block()
        state.withLock { $0.executing = false }
        return true
    }

    func runReady() {
        for _ in 0..<100 {
            if !runOne() { return }
        }
        XCTFail("Drain queue did not reach quiescence in 100 explicit turns")
    }

    func runReadyIfIdle() {
        if !state.withLock({ $0.executing }) { runReady() }
    }

    func releaseDelayed() {
        state.withLock {
            $0.ready.append(contentsOf: $0.delayed)
            $0.delayed.removeAll()
        }
    }
}

private final class DrainFileManager: SentryFileManager {
    var afterEmptySnapshot: (() -> Void)?

    override func getOldestEnvelope() -> SentryFileContents? {
        let snapshot = super.getOldestEnvelope()
        if snapshot == nil, let callback = afterEmptySnapshot {
            afterEmptySnapshot = nil
            callback()
        }
        return snapshot
    }
}

private final class DrainRequestManager: NSObject, RequestManager {
    private struct State {
        var requests: [URLRequest] = []
        var completions: [SentryRequestOperationFinished?] = []
        var closed = false
    }
    private let state = SentryMutex(State())

    var isReady: Bool { true }
    var count: Int { state.withLock { $0.requests.count } }

    func add(_ request: URLRequest, completionHandler: SentryRequestOperationFinished?) {
        state.withLock {
            $0.requests.append(request)
            $0.completions.append(completionHandler)
        }
    }

    func completeNext(response: HTTPURLResponse?) {
        let completion = state.withLock { $0.completions.removeFirst() }
        completion?(response, nil)
    }

    func close() { state.withLock { $0.closed = true } }
}

private final class DrainFixture {
    static var okResponse: HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200,
                        httpVersion: nil, headerFields: nil)!
    }
    let queue: DrainQueue
    let requests = DrainRequestManager()
    let flushes = DrainFlushProbe()
    let reachability = TestSentryReachability()
    let date = TestCurrentDateProvider()
    let files: DrainFileManager
    let options: Options

    init(queue: DrainQueue = DrainQueue()) throws {
        self.queue = queue
        options = Options()
        options.dsn = TestConstants.dsnAsString(username: "SentryHttpTransportDrainTests")
        options.cacheDirectoryPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString).path
        files = DrainFileManager(helper: try SentryFileManagerHelper(options: options), dateProvider: date,
                                 dispatchQueueWrapper: TestSentryDispatchQueueWrapper())
    }

    func makeTransport(requestManager: RequestManager? = nil) throws -> SentryHttpTransport {
        let rateLimits = DefaultRateLimits(
            retryAfterHeaderParser: RetryAfterHeaderParser(httpDateParser: HttpDateParser(), currentDateProvider: date),
            andRateLimitParser: RateLimitParser(currentDateProvider: date), currentDateProvider: date)
        let transport = SentryHttpTransport(dsn: try XCTUnwrap(options.parsedDsn), sendClientReports: false,
                                   cachedEnvelopeSendDelay: 0, dateProvider: date, fileManager: files,
                                   requestManager: requestManager ?? requests, requestBuilder: TestNSURLRequestBuilder(),
                                   rateLimits: rateLimits, envelopeRateLimit: EnvelopeRateLimit(rateLimits: rateLimits),
                                   dispatchQueueWrapper: queue, reachability: reachability)
        transport.setDrainFlushStateCallback { [flushes] identity, activated, terminal in
            flushes.record(identity: identity, activated: activated, terminal: terminal)
        }
        transport.setDrainFlushCleanupCallback { [flushes] identity, result in
            flushes.cleanup?(identity, result)
        }
        return transport
    }

    func cleanUp() { files.deleteAllFolders() }
}

private final class DrainFlushCall {
    let returned = XCTestExpectation(description: "Flush caller returned")
    private let storedResult = SentryMutex<SentryFlushResult?>(nil)
    var result: SentryFlushResult? { storedResult.withLock { $0 } }

    init(transport: Transport) {
        DispatchQueue(label: "SentryHttpTransportDrainTests.flush").async { [self] in
            let result = transport.flush(5)
            storedResult.withLock { $0 = result }
            returned.fulfill()
        }
    }
}

private final class DrainFlushProbe {
    struct Snapshot {
        let identity: NSObject
        let activated: Bool
        let terminal: Bool
    }
    private struct State {
        var identities: [ObjectIdentifier] = []
        var snapshots: [ObjectIdentifier: Snapshot] = [:]
        var cleanup: ((NSObject, Int) -> Void)?
    }
    private let state = SentryMutex(State())

    var count: Int { state.withLock { $0.identities.count } }
    var cleanup: ((NSObject, Int) -> Void)? {
        get { state.withLock { $0.cleanup } }
        set { state.withLock { $0.cleanup = newValue } }
    }

    func record(identity: NSObject, activated: Bool, terminal: Bool) {
        state.withLock {
            let key = ObjectIdentifier(identity)
            if $0.snapshots[key] == nil { $0.identities.append(key) }
            $0.snapshots[key] = Snapshot(identity: identity, activated: activated, terminal: terminal)
        }
    }

    func snapshot(at index: Int) -> Snapshot? {
        state.withLock {
            guard let identity = $0.identities.dropFirst(index).first else { return nil }
            return $0.snapshots[identity]
        }
    }
}
