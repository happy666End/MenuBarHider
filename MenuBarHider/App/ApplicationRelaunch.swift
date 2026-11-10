import AppKit
import Darwin
import Foundation

enum ApplicationRelaunch {
    private static let helperArgument = "--relaunch-after-exit"

    static func prepare(from applicationURL: URL) throws -> Process {
        guard let executableURL = Bundle(url: applicationURL)?.executableURL,
            FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            throw CocoaError(.executableNotLoadable)
        }
        let helper = Process()
        helper.executableURL = executableURL
        helper.arguments = [helperArgument, String(ProcessInfo.processInfo.processIdentifier), applicationURL.path]
        helper.standardInput = FileHandle.nullDevice
        return helper
    }

    static func requestTermination(
        helper: Process, notifications: NotificationCenter = .default, terminate: () -> Void
    ) {
        var observer: NSObjectProtocol?
        observer = notifications.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            guard let activeObserver = observer else { return }
            observer = nil
            notifications.removeObserver(activeObserver)
            do { try helper.run() } catch {
                Log.ui.error("Relaunch helper failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        defer {
            if let activeObserver = observer {
                observer = nil
                notifications.removeObserver(activeObserver)
            }
        }
        // The delegate replies synchronously; no willTerminate notification means cancellation.
        terminate()
    }

    static func runHelperIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.dropFirst().first == helperArgument else { return false }
        do {
            guard arguments.count == 4, let parentPID = Int32(arguments[2]), parentPID > 1 else {
                throw POSIXError(.EINVAL)
            }
            let applicationURL = URL(fileURLWithPath: arguments[3], isDirectory: true)
            try perform(after: parentPID, lockURL: ApplicationInstanceLock.defaultURL, timeout: 60) {
                try open(applicationURL)
            }
        } catch {
            Log.ui.error("Relaunch handoff failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    static func perform(
        after processIdentifier: Int32, lockURL: URL, timeout: TimeInterval,
        launch: () throws -> Void
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try waitForExit(of: processIdentifier, deadline: deadline)
        try waitForUnlock(at: lockURL, deadline: deadline)
        try launch()
    }

    private static func waitForExit(of processIdentifier: Int32, deadline: TimeInterval) throws {
        let descriptor = kqueue()
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        var registration = kevent(
            ident: UInt(processIdentifier), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(descriptor, &registration, 1, nil, 0, nil) == 0 else {
            if errno == ESRCH { return }
            throw posixError()
        }
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
            var timeout = timespec(
                tv_sec: Int(remaining), tv_nsec: Int((remaining - floor(remaining)) * 1_000_000_000))
            var event = kevent()
            let count = kevent(descriptor, nil, 0, &event, 1, &timeout)
            if count > 0 {
                if event.flags & UInt16(EV_ERROR) != 0 {
                    if event.data == ESRCH { return }
                    throw POSIXError(POSIXErrorCode(rawValue: Int32(event.data)) ?? .EIO)
                }
                return
            }
            if count == 0 { throw POSIXError(.ETIMEDOUT) }
            if errno != EINTR { throw posixError() }
        }
    }

    private static func waitForUnlock(at url: URL, deadline: TimeInterval) throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let lock = try ApplicationInstanceLock.acquire(url: url) {
                withExtendedLifetime(lock) {}
                return
            }
            Thread.sleep(forTimeInterval: min(0.025, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private static func open(_ applicationURL: URL) throws {
        let opener = Process()
        let finished = DispatchSemaphore(value: 0)
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-n", applicationURL.path]
        opener.terminationHandler = { _ in finished.signal() }
        try opener.run()
        guard finished.wait(timeout: .now() + 10) == .success else {
            if opener.isRunning { opener.terminate() }
            throw POSIXError(.ETIMEDOUT)
        }
        guard opener.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
