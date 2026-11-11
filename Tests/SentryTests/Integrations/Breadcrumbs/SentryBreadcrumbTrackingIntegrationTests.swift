@_spi(Private) import _SentryPrivate
@_spi(Private) import SentryTestUtils
@_spi(Private) @testable import Sentry
import XCTest

class SentryBreadcrumbTrackingIntegrationTests: XCTestCase {

    private final class EnteredBreadcrumbHub: SentryHubInternal {
        var onClientRead: (() -> Void)?

        override func getClient() -> SentryClientInternal? {
            let callback = onClientRead
            onClientRead = nil
            callback?()
            return super.getClient()
        }
    }
    
    private class Fixture {
        private let dateProvider = TestCurrentDateProvider()
        private let dispatchQueueWrapper = TestSentryDispatchQueueWrapper()

        let fileManager: TestFileManager
        let notificationCenterWrapper = TestNSNotificationCenterWrapper()
        let defaultOptions: Options

        init() throws {
            let options = Options()
            options.dsn = TestConstants.dsnForTestCase(type: SentryBreadcrumbTrackingIntegrationTests.self)
            options.enableAutoBreadcrumbTracking = true
            defaultOptions = options

            fileManager = try TestFileManager(
                options: options,
                dateProvider: dateProvider,
                dispatchQueueWrapper: dispatchQueueWrapper
            )
        }

        func getSut(options: Options? = nil) throws -> SentryAutoBreadcrumbTrackingIntegration<SentryDependencyContainer> {
            let container = SentryDependencyContainer.sharedInstance()
            container.fileManager = fileManager
            container.notificationCenterWrapper = notificationCenterWrapper
            
            return try XCTUnwrap(SentryAutoBreadcrumbTrackingIntegration(
                with: options ?? defaultOptions,
                dependencies: container
            ))
        }
    }
    
    private var fixture: Fixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try Fixture()
        
        // Ignore the reachability callbacks, so we don't get connectivity breadcrumbs.
        SentryDependencyContainer.sharedInstance().reachability.setReachabilityIgnoreActualCallback(true)
    }

    override func tearDown() {
        super.tearDown()
        clearTestState()
    }
    
    func test_enableAutoBreadcrumbTracking_Disabled() {
        let options = Options()
        options.enableAutoBreadcrumbTracking = false

        let container = SentryDependencyContainer.sharedInstance()
        container.fileManager = fixture.fileManager
        container.notificationCenterWrapper = fixture.notificationCenterWrapper
        
        let sut = SentryAutoBreadcrumbTrackingIntegration(with: options, dependencies: container)

        XCTAssertNil(sut, "Integration should return nil when enableAutoBreadcrumbTracking is disabled")
    }
    
    func testInstall() throws {
        let scope = Scope()
        let hub = SentryHubInternal(client: TestClient(options: Options()), andScope: scope)
        SentrySDKInternal.setCurrentHub(hub)

        let sut = try fixture.getSut()
        defer {
            sut.uninstall()
        }
        // Make sure there are no other breadcrumbs in the scope
        scope.clearBreadcrumbs()
        
        // Add a sample breadcrumb
        let crumb = TestData.crumb
        sut.add(crumb)
        
        let serializedScope = scope.serialize()
        let breadcrumbs = try XCTUnwrap(serializedScope["breadcrumbs"] as? [[String: Any]], "no scope.breadcrumbs")
        XCTAssertEqual(1, breadcrumbs.count)
        XCTAssertEqual(crumb.category, try XCTUnwrap(breadcrumbs[0]["category"] as? String))
        XCTAssertEqual(crumb.type, try XCTUnwrap(breadcrumbs[0]["type"] as? String))
    }

    func testAdd_whenOwnerClosedDuringEnteredCallback_shouldNotMutateReplacementScope() throws {
        let ownerClient = try XCTUnwrap(TestClient(options: fixture.defaultOptions))
        let owner = EnteredBreadcrumbHub(client: ownerClient, andScope: Scope())
        SentrySDKInternal.setCurrentHub(owner)
        let sut = try fixture.getSut()
        defer { sut.uninstall() }
        owner.scope.clearBreadcrumbs()
        let replacement = SentryHubInternal(client: TestClient(options: fixture.defaultOptions), andScope: Scope())
        var entered = false
        owner.onClientRead = {
            entered = true
            owner.close()
            owner.bindClient(nil)
            SentrySDKInternal.setCurrentHub(replacement)
        }

        sut.add(TestData.crumb)

        XCTAssertTrue(entered, "The A automatic breadcrumb callback must enter before the lifetime handoff")
        XCTAssertEqual(replacement.scope.breadcrumbs().count, 0, "Entered A automatic breadcrumb must never mutate B scope")
        XCTAssertEqual(owner.scope.breadcrumbs().count, 0)
        let fresh = try fixture.getSut()
        defer { fresh.uninstall() }
        replacement.scope.clearBreadcrumbs()
        fresh.add(TestData.crumb)
        XCTAssertEqual(replacement.scope.breadcrumbs().count, 1, "Fresh B automatic breadcrumbs must remain enabled")
    }

    func testAdd_whenOwnerEligibleAndGlobalHubChanges_shouldUseOwnerScope() throws {
        let owner = SentryHubInternal(client: TestClient(options: fixture.defaultOptions), andScope: Scope())
        SentrySDKInternal.setCurrentHub(owner)
        let sut = try fixture.getSut()
        defer { sut.uninstall() }
        owner.scope.clearBreadcrumbs()
        let replacement = SentryHubInternal(client: TestClient(options: fixture.defaultOptions), andScope: Scope())
        SentrySDKInternal.setCurrentHub(replacement)

        sut.add(TestData.crumb)

        XCTAssertEqual(owner.scope.breadcrumbs().count, 1, "An eligible A producer must mutate A scope")
        XCTAssertEqual(replacement.scope.breadcrumbs().count, 0, "A producer must not resolve the global B hub")
    }

    func testAdd_whenOwnerClientClosedButStillBound_shouldDrop() throws {
        let owner = EnteredBreadcrumbHub(client: TestClient(options: fixture.defaultOptions), andScope: Scope())
        SentrySDKInternal.setCurrentHub(owner)
        let sut = try fixture.getSut()
        defer { sut.uninstall() }
        owner.scope.clearBreadcrumbs()
        let replacement = SentryHubInternal(client: TestClient(options: fixture.defaultOptions), andScope: Scope())
        owner.onClientRead = {
            owner.close()
            SentrySDKInternal.setCurrentHub(replacement)
        }

        sut.add(TestData.crumb)

        XCTAssertEqual(owner.scope.breadcrumbs().count, 0, "A closed client must not admit another automatic breadcrumb")
        XCTAssertEqual(replacement.scope.breadcrumbs().count, 0, "A closed producer must not fall back to B")
    }

    func testAdd_whenOwnerReleased_shouldDropWithoutRetainingOrResolvingGlobalHub() throws {
        var sut: SentryAutoBreadcrumbTrackingIntegration<SentryDependencyContainer>?
        weak var weakOwner: SentryHubInternal?
        try autoreleasepool {
            let owner = SentryHubInternal(client: TestClient(options: fixture.defaultOptions), andScope: Scope())
            weakOwner = owner
            SentrySDKInternal.setCurrentHub(owner)
            sut = try fixture.getSut()
        }
        let replacement = SentryHubInternal(client: TestClient(options: fixture.defaultOptions), andScope: Scope())
        SentrySDKInternal.setCurrentHub(replacement)
        let integration = try XCTUnwrap(sut)
        defer { integration.uninstall() }

        XCTAssertNil(weakOwner, "The producer must not retain its originating hub")
        integration.add(TestData.crumb)

        XCTAssertEqual(replacement.scope.breadcrumbs().count, 0, "An ownerless producer must never fall back to B")
    }
}
