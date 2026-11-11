#if (os(iOS) || os(tvOS) || os(visionOS)) && !SENTRY_NO_UI_FRAMEWORK

internal import _SentryPrivate
import Foundation

/// The frame source for OS versions that have `UIUpdateLink`.
///
/// A `CADisplayLink` makes the display and the main thread wake up for every frame for as long as it
/// runs, even when nothing on screen changes. This source only uses callbacks for work that happens
/// anyway. The run loop observer measures how long the main thread is blocked, which is what turns
/// into slow and frozen frames. The UI update observer reports the frame duration of the display
/// and every frame UIKit produces.
///
/// The total frame count is the number of frames UIKit produces. It doesn't grow while nothing on
/// screen changes, while a display link counts every frame of the display.
final class SentryUpdateLinkFrameSource: SentryFrameSource {

    // A frame duration outside of these frame rates isn't one of a display, for example when UIKit
    // shortens the deadline of a UI update to present it with low latency.
    private static let validFrameRates: ClosedRange<Double> = 10...240

    private let dateProvider: SentryCurrentDateProvider
    private let runLoopObserver: SentryMainRunLoopActivityObserving
    private let uiUpdateObserver: SentryUIUpdateObserving
    private weak var delegate: SentryFrameSourceDelegate?

    // Accessed only from main thread (run loop and UI update observer callbacks)
    private var frameRate: UInt64 = 60
    private var slowFrameThresholdNanos = SentryUpdateLinkFrameSource.slowFrameThresholdNanos(60)
    /// When the main thread started the work it's on, or `nil` while it waits for work and before
    /// the first run loop activity.
    private var workStart: UInt64?
    /// Whether UIKit produced a frame during the work the main thread is on.
    private var workProducedFrame = false

    /// Written by the main thread, read by the threads that start and finish spans.
    private let frameCount = SentryMutex<UInt>(0)

    var requiresContinuousFrames: Bool {
        get { uiUpdateObserver.requiresContinuousUpdates }
        set { uiUpdateObserver.requiresContinuousUpdates = newValue }
    }

    init(
        dateProvider: SentryCurrentDateProvider,
        runLoopObserver: SentryMainRunLoopActivityObserving,
        uiUpdateObserver: SentryUIUpdateObserving
    ) {
        self.dateProvider = dateProvider
        self.runLoopObserver = runLoopObserver
        self.uiUpdateObserver = uiUpdateObserver
    }

    deinit {
        // This can be deallocated on any thread. Stopping the run loop observer is thread-safe, and
        // the UI update observer cleans up after itself.
        runLoopObserver.stop()
    }

    func start(delegate: SentryFrameSourceDelegate) {
        self.delegate = delegate

        // The work that started tracking has nothing to compare to, like the first callback of a
        // display link.
        workStart = nil
        workProducedFrame = false

        runLoopObserver.start { [weak self] activity in
            self?.runLoopActivityObserved(activity)
        }
        uiUpdateObserver.start { [weak self] frameDuration in
            self?.uiUpdateObserved(frameDuration: frameDuration)
        }
    }

    func stop() {
        runLoopObserver.stop()
        uiUpdateObserver.stop()

        workStart = nil
        workProducedFrame = false
    }

    func totalFrames() -> UInt {
        frameCount.withLock { $0 }
    }

    func resetFrames() {
        frameCount.withLock { $0 = 0 }
    }

    /// The time between two run loop activities is time the main thread spent on one piece of work,
    /// during which it couldn't produce a frame. A `CADisplayLink` sees the same time as the
    /// duration between two of its callbacks, so both frame sources report it the same way.
    ///
    /// This runs multiple times per run loop iteration. It must not lock or allocate unless the main
    /// thread was blocked.
    private func runLoopActivityObserved(_ activity: CFRunLoopActivity) {
        let now = dateProvider.systemTime()
        let isWaiting = activity == .beforeWaiting

        let endedWorkStart = workStart
        let endedWorkProducedFrame = workProducedFrame
        workStart = isWaiting ? nil : now
        workProducedFrame = false

        guard let delegate else { return }

        if let endedWorkStart, now > endedWorkStart, now - endedWorkStart > slowFrameThresholdNanos {
            // UIKit doesn't produce a frame when the work that blocked the main thread changed
            // nothing on screen. The delayed frame still counts as one frame, like with a display
            // link. Otherwise there could be more slow and frozen frames than frames in total.
            if !endedWorkProducedFrame {
                frameCount.withLock { $0 += 1 }
            }
            delegate.frameSource(didDelayFrameFrom: endedWorkStart, to: now, duration: nanosecondsToTimeInterval(now - endedWorkStart))
        }

        // Without reporting that the main thread is idle, the time the app does nothing would count
        // as the delay of a frame in flight.
        if isWaiting {
            delegate.frameSourceDidBecomeIdle()
        } else {
            delegate.frameSource(didStartFrameAt: now)
        }
    }

    private func uiUpdateObserved(frameDuration: CFTimeInterval) {
        let now = dateProvider.systemTime()

        let reportedFrameRate = frameDuration > 0 ? round(1 / frameDuration) : 0
        if Self.validFrameRates.contains(reportedFrameRate) && UInt64(reportedFrameRate) != frameRate {
            frameRate = UInt64(reportedFrameRate)
            slowFrameThresholdNanos = Self.slowFrameThresholdNanos(frameRate)
        }

        frameCount.withLock { $0 += 1 }
        workProducedFrame = true

        delegate?.frameSource(didMeasureFrameRate: frameRate, at: now)
        delegate?.frameSourceDidRenderFrame()
    }

    private static func slowFrameThresholdNanos(_ frameRate: UInt64) -> UInt64 {
        timeIntervalToNanoseconds(SentryFramesTracker.slowFrameThreshold(frameRate))
    }
}

#endif
