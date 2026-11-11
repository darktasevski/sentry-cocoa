@_spi(Private) import SentryTestUtils
@_spi(Private) @testable import Sentry
import ObjectiveC
import XCTest

final class SentryQueueableRequestManagerTests: XCTestCase {
    private let request = URLRequest(url: URL(string: "https://close-seal.invalid/envelope")!)

    func testAdd_whenOpen_shouldConstructRequest() throws {
        let session = CloseSealRecordingSession()
        defer { session.invalidateAndCancel() }
        let sut = SentryQueueableRequestManager(session: session)
        let queue = try XCTUnwrap(sut.value(forKey: "queue") as? OperationQueue)
        queue.isSuspended = true

        (sut as RequestManager).add(request, completionHandler: nil)

        XCTAssertEqual(session.recordedTasks.count, 1)
        XCTAssertEqual(queue.operationCount, 1)
        queue.cancelAllOperations()
        queue.isSuspended = false
    }

    func testClose_whenClosedBeforeAdd_shouldRejectWithoutConstructingTask() {
        let session = CloseSealRecordingSession()
        defer { session.invalidateAndCancel() }
        let sut = SentryQueueableRequestManager(session: session)
        guard closeForSealTest(sut) else { return }
        session.markCloseReturned()
        let cancelled = expectation(description: "Late request rejected")

        (sut as RequestManager).add(request) { response, error in
            expectCloseSealLock(sut, held: false)
            XCTAssertNil(response)
            XCTAssertEqual((error as NSError?)?.domain, NSURLErrorDomain)
            XCTAssertEqual((error as NSError?)?.code, NSURLErrorCancelled)
            cancelled.fulfill()
        }

        XCTAssertEqual(session.recordedTasks.count, 0)
        XCTAssertEqual(session.recordedTasksCreatedAfterClose.count, 0)
        wait(for: [cancelled], timeout: 1)
        XCTAssertEqual(session.invalidationCalls.count, 0)
    }

    func testClose_whenAddIsConstructing_shouldSealAfterConstructionAndCancelTask() throws {
        let session = CloseSealRecordingSession()
        defer { session.invalidateAndCancel() }
        let sut = SentryQueueableRequestManager(session: session)
        let queue = CloseSealCheckingOperationQueue()
        sut.setValue(queue, forKey: "queue")
        queue.isSuspended = true
        defer {
            session.beforeTaskConstruction = nil
            queue.beforeEnqueue = nil
            queue.beforeSnapshot = nil
        }
        let constructionProbes = Invocations<Void>()
        session.beforeTaskConstruction = {
            constructionProbes.record(())
            expectCloseSealLock(sut, held: true)
        }
        queue.beforeEnqueue = {
            expectCloseSealLock(sut, held: true)
        }
        queue.beforeSnapshot = {
            expectCloseSealLock(sut, held: true)
        }

        (sut as RequestManager).add(request, completionHandler: nil)
        guard closeForSealTest(sut) else {
            queue.cancelAllOperations()
            queue.isSuspended = false
            return
        }
        session.markCloseReturned()

        XCTAssertEqual(session.recordedTasks.count, 1)
        XCTAssertEqual(constructionProbes.count, 1)
        XCTAssertEqual(queue.enqueueProbes.count, 1)
        XCTAssertEqual(queue.snapshotProbes.count, 1)
        XCTAssertEqual(session.recordedTasksCreatedAfterClose.count, 0)
        XCTAssertTrue(session.recordedTasks.invocations.allSatisfy { $0.state == .canceling || $0.state == .completed })
        queue.isSuspended = false
    }

    func testClose_whenRequestsActiveAndQueued_shouldCancelAllAdmittedTasks() throws {
        let session = CloseSealRecordingSession()
        defer { session.invalidateAndCancel() }
        let sut = SentryQueueableRequestManager(session: session)
        let queue = try XCTUnwrap(sut.value(forKey: "queue") as? OperationQueue)
        queue.maxConcurrentOperationCount = 1
        let active = expectation(description: "First request active")
        session.protocolStarted = { active.fulfill() }
        (sut as RequestManager).add(request, completionHandler: nil)
        wait(for: [active], timeout: 1)
        queue.isSuspended = true
        (sut as RequestManager).add(request, completionHandler: nil)
        guard closeForSealTest(sut) else {
            queue.cancelAllOperations()
            queue.isSuspended = false
            return
        }

        XCTAssertEqual(session.recordedTasks.count, 2)
        XCTAssertTrue(session.recordedTasks.invocations.allSatisfy { $0.state == .canceling || $0.state == .completed })
        XCTAssertEqual(session.invalidationCalls.count, 0)
        queue.isSuspended = false
    }

    func testClose_whenQueuedOperationRunsLater_shouldKeepPreconstructedTaskCancelled() throws {
        let session = CloseSealRecordingSession()
        defer { session.invalidateAndCancel() }
        let sut = SentryQueueableRequestManager(session: session)
        let queue = try XCTUnwrap(sut.value(forKey: "queue") as? OperationQueue)
        queue.isSuspended = true
        (sut as RequestManager).add(request, completionHandler: nil)
        let operation = try XCTUnwrap(queue.operations.first)
        let task = try XCTUnwrap(session.recordedTasks.first)
        guard closeForSealTest(sut) else {
            queue.cancelAllOperations()
            queue.isSuspended = false
            return
        }

        // Exercise a delayed resume on the already constructed Foundation task after cancellation.
        task.resume()

        XCTAssertTrue(operation.isCancelled)
        XCTAssertTrue(task.state == .canceling || task.state == .completed)
        XCTAssertEqual(session.recordedTasks.count, 1)
        queue.isSuspended = false
    }

    func testClose_whenCompletionRetriesLater_shouldRejectRetryWithoutNewTask() throws {
        let session = CloseSealRecordingSession()
        defer { session.invalidateAndCancel() }
        let sut = SentryQueueableRequestManager(session: session)
        let queue = try XCTUnwrap(sut.value(forKey: "queue") as? OperationQueue)
        queue.isSuspended = true
        let rejected = expectation(description: "Late retry rejected")
        rejected.assertForOverFulfill = false
        (sut as RequestManager).add(request) { _, _ in
            (sut as RequestManager).add(self.request) { _, error in
                XCTAssertEqual((error as NSError?)?.code, NSURLErrorCancelled)
                rejected.fulfill()
            }
        }
        let completion = try XCTUnwrap(session.completions.first)
        guard closeForSealTest(sut) else {
            queue.cancelAllOperations()
            queue.isSuspended = false
            return
        }
        session.markCloseReturned()

        completion(nil, nil, nil)

        XCTAssertEqual(session.recordedTasks.count, 1)
        XCTAssertEqual(session.recordedTasksCreatedAfterClose.count, 0)
        wait(for: [rejected], timeout: 1)
        queue.isSuspended = false
    }

    func testClose_whenRepeatedAndReenteredFromRejection_shouldRemainSealed() {
        let session = CloseSealRecordingSession()
        defer { session.invalidateAndCancel() }
        let sut = SentryQueueableRequestManager(session: session)
        guard closeForSealTest(sut) else { return }
        guard closeForSealTest(sut) else { return }
        let callbackReturned = expectation(description: "Reentrant close returned")

        (sut as RequestManager).add(request) { _, error in
            expectCloseSealLock(sut, held: false)
            XCTAssertEqual((error as NSError?)?.code, NSURLErrorCancelled)
            _ = closeForSealTest(sut)
            callbackReturned.fulfill()
        }

        wait(for: [callbackReturned], timeout: 1)
        XCTAssertEqual(session.recordedTasks.count, 0)
    }
}

private func expectCloseSealLock(_ object: NSObject, held: Bool, file: StaticString = #filePath, line: UInt = #line) {
    // Probe on the calling thread without a competing operation. Restore a successful exit
    // immediately so the enclosing @synchronized retains its original recursion depth.
    let result = objc_sync_exit(object)
    if result == 0 {
        objc_sync_enter(object)
    }
    XCTAssertEqual(result, held ? 0 : -1, held
        ? "Task construction, enqueue, and close snapshot must share the manager lock"
        : "Rejection callbacks must run outside the manager lock", file: file, line: line)
}

private final class CloseSealCheckingOperationQueue: OperationQueue, @unchecked Sendable {
    var beforeEnqueue: (() -> Void)?
    var beforeSnapshot: (() -> Void)?
    let enqueueProbes = Invocations<Void>()
    let snapshotProbes = Invocations<Void>()

    override func addOperation(_ operation: Operation) {
        enqueueProbes.record(())
        beforeEnqueue?()
        super.addOperation(operation)
    }

    override var operations: [Operation] {
        snapshotProbes.record(())
        beforeSnapshot?()
        return super.operations
    }
}

@discardableResult
func closeForSealTest(_ object: NSObjectProtocol, file: StaticString = #filePath, line: UInt = #line) -> Bool {
    let selector = NSSelectorFromString("close")
    guard object.responds(to: selector), let object = object as? NSObject else {
        XCTFail("\(type(of: object)) must implement the internal close seal", file: file, line: line)
        return false
    }
    object.perform(selector)
    return true
}

final class CloseSealRecordingSession: CloseSealURLSessionStub, @unchecked Sendable {
    let recordedTasks = Invocations<URLSessionDataTask>()
    let recordedTasksCreatedAfterClose = Invocations<URLSessionDataTask>()
    let completions = Invocations<@Sendable (Data?, URLResponse?, Error?) -> Void>()
    let invalidationCalls = Invocations<Void>()
    var beforeTaskConstruction: (() -> Void)?
    var protocolStarted: (() -> Void)?
    private let closed = SentryMutex(false)
    private let backingSession: URLSession
    var didCloseReturn: Bool { closed.withLock { $0 } }

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloseSealURLProtocol.self]
        backingSession = URLSession(configuration: configuration)
        super.init()
    }

    func markCloseReturned() { closed.withLock { $0 = true } }

    override func dataTask(with request: URLRequest, completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        beforeTaskConstruction?()
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        if let protocolStarted {
            URLProtocol.setProperty(protocolStarted, forKey: "closeSealStarted", in: mutableRequest)
        }
        let task = backingSession.dataTask(with: mutableRequest as URLRequest, completionHandler: completionHandler)
        recordedTasks.record(task)
        completions.record(completionHandler)
        if didCloseReturn { recordedTasksCreatedAfterClose.record(task) }
        return task
    }

    override func invalidateAndCancel() {
        invalidationCalls.record(())
        backingSession.invalidateAndCancel()
    }
}

private final class CloseSealURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        (URLProtocol.property(forKey: "closeSealStarted", in: request) as? () -> Void)?()
    }
    override func stopLoading() { }
}
