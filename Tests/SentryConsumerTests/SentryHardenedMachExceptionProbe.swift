// A consumer process for test-hardened-mach-exceptions.sh, which signs it with the Enhanced
// Security platform-restrictions entitlement. Each mode is one process launch:
//   control  registers an EXCEPTION_DEFAULT port, which the restriction must kill
//   start    starts the SDK and exits
//   crash    starts the SDK and raises EXC_BAD_ACCESS
//   report   starts the SDK and prints the replayed crash event, which beforeSend drops
import Darwin
import Foundation
import Sentry

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let mode = CommandLine.arguments.dropFirst().first ?? ""
let cacheDirectory = ProcessInfo.processInfo.environment["SENTRY_PROBE_CACHE"] ?? ""

if mode == "control" {
    var port = mach_port_t(MACH_PORT_NULL)
    var kr = mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
    if kr == KERN_SUCCESS {
        kr = mach_port_insert_right(
            mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
    }
    if kr == KERN_SUCCESS {
        let behavior = exception_behavior_t(bitPattern: UInt32(EXCEPTION_DEFAULT) | MACH_EXCEPTION_CODES)
        kr = task_set_exception_ports(
            mach_task_self_, exception_mask_t(EXC_MASK_BAD_ACCESS), port, behavior, THREAD_STATE_NONE)
    }
    emit("control survived kr=\(kr)")
    exit(0)
}

let reportSeen = DispatchSemaphore(value: 0)
SentrySDK.start { options in
    // Nothing is transmitted: the DSN names a closed local port and beforeSend drops every event.
    options.dsn = "http://public@127.0.0.1:9/1"
    options.cacheDirectoryPath = cacheDirectory
    options.enableAutoSessionTracking = false
    options.enableAppHangTracking = false
    options.beforeSend = { event in
        if let exception = event.exceptions?.first, let mechanism = exception.mechanism {
            let mach = mechanism.meta?.machException ?? [:]
            let crashedThread = event.threads?.first { $0.crashed?.boolValue == true }
            let frames = crashedThread?.stacktrace?.frames.count ?? 0
            emit("report mechanism=\(mechanism.type) exception=\(mach["name"] ?? "none") "
                + "code=\(mach["code"] ?? "none") subcode=\(mach["subcode"] ?? "none")")
            // The probe faults on the main thread, so that is the thread the report must blame.
            let isMain = crashedThread?.isMain?.boolValue == true
            emit("report crashedThreadIsMain=\(isMain) crashedThreadHasFrames=\(frames > 0)")
            reportSeen.signal()
        }
        return nil
    }
}
emit("started lastRunDidCrash=\(SentrySDK.lastRunStatus == .didCrash)")

switch mode {
case "crash":
    UnsafeMutablePointer<Int>(bitPattern: 0x10)!.pointee = 1
case "report":
    if reportSeen.wait(timeout: .now() + 20) == .timedOut {
        emit("report missing")
        exit(1)
    }
default:
    break
}
exit(0)
