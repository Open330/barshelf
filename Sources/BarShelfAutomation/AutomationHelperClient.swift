import Foundation
import notify

/// The app's side of the channel: starts the helper (or adopts one that
/// outlived a previous app), sends it requests and relays its status.
package final class AutomationHelperClient {
    private let executable: URL
    private let channel: AutomationHelperChannel
    private let build: String
    private let appPID: Int32
    private let exitTimeout: TimeInterval
    private let forceQuit: (Int32) -> Void
    private var process: Process?
    private var exitSource: DispatchSourceProcess?
    private var tokens: [Int32] = []
    private var wanted = false
    private var respawns: [Date] = []
    package private(set) var status: AutomationHelperStatus?

    package var onStatus: ((AutomationHelperStatus) -> Void)?
    /// The helper is gone and could not be brought back.
    package var onHelperLost: (() -> Void)?
    /// A quit meant for the app reached the helper.
    package var onQuitRequested: (() -> Void)?
    /// An "open BarShelf" reached the helper.
    package var onReopenRequested: (() -> Void)?

    package init(executable: URL, channel: AutomationHelperChannel = .standard,
                 build: String = AutomationHelperChannel.currentBuild, appPID: Int32 = getpid(),
                 exitTimeout: TimeInterval = 2,
                 forceQuit: @escaping (Int32) -> Void = { kill($0, SIGTERM) }) {
        self.executable = executable
        self.channel = channel
        self.build = build
        self.appPID = appPID
        self.exitTimeout = exitTimeout
        self.forceQuit = forceQuit
        tokens.append(channel.observe(channel.statusName) { [weak self] in self?.refresh() })
        tokens.append(channel.observe(channel.quitAppName) { [weak self] in self?.onQuitRequested?() })
        tokens.append(channel.observe(channel.reopenAppName) { [weak self] in self?.onReopenRequested?() })
    }

    deinit {
        tokens.forEach(channel.cancel)
        exitSource?.cancel()
    }

    /// Whether a helper is alive right now.
    package var isHelperAlive: Bool { helperPID != nil }

    private var helperPID: Int32? {
        if let process, process.isRunning { return process.processIdentifier }
        if let status, status.pid != process?.processIdentifier, AutomationHelperChannel.isAlive(status.pid) {
            return status.pid
        }
        return nil
    }

    private func refresh() {
        guard let latest = channel.read(AutomationHelperStatus.self, from: channel.statusURL),
              latest != status else { return }
        // A status file left by a helper that is gone says nothing.
        if let process, process.isRunning {
            guard latest.pid == process.processIdentifier else { return }
        } else {
            guard AutomationHelperChannel.isAlive(latest.pid) else { return }
        }
        status = latest
        onStatus?(latest)
    }

    /// Makes sure a helper of this build is running and owned by this app.
    /// Returns once it has answered, or false if it could not be started.
    @discardableResult
    package func ensureRunning() -> Bool {
        wanted = true
        if helperPID != nil, status?.ownerPID == appPID, status?.build == build { return true }
        // One that outlived a previous app instance: take it over if it is
        // this build, replace it otherwise.
        if let existing = channel.read(AutomationHelperStatus.self, from: channel.statusURL),
           existing.pid != appPID, AutomationHelperChannel.isAlive(existing.pid) {
            if existing.build == build {
                watch(existing.pid)
                status = existing
                if send(.init(kind: .adopt, appPID: appPID))?.reply?.ok == true { return true }
            }
            terminate(existing)
        }
        return spawn()
    }

    private func spawn() -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = [AutomationHelperProcess.argument, "--app-pid", "\(appPID)"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Nothing left over from an earlier run for the new helper to read.
        try? FileManager.default.removeItem(at: channel.requestURL)
        do { try process.run() } catch {
            NSLog("BarShelf could not start its keyboard helper: %@", error.localizedDescription)
            return false
        }
        self.process = process
        status = nil
        watch(process.processIdentifier)
        // Its first status means it is listening; a request posted earlier
        // could be missed.
        return wait(timeout: 5) { self.status?.pid == process.processIdentifier }
    }

    /// Sends a request and waits for the helper's answer to it. Nil when the
    /// helper did not answer in time.
    package func send(_ request: AutomationHelperRequest, timeout: TimeInterval = 5) -> AutomationHelperStatus? {
        do { try channel.write(request, to: channel.requestURL) } catch { return nil }
        channel.post(channel.requestName)
        guard wait(timeout: timeout, until: { self.status?.reply?.id == request.id }) else { return nil }
        return status
    }

    package func apply(source: String) -> AutomationHelperStatus? {
        send(.init(kind: .apply, appPID: appPID, source: source))
    }

    /// Tells the helper to stop and exit. With `waitForExit`, returns once
    /// its keys are released and it is gone.
    package func stop(waitForExit: Bool = true) {
        wanted = false
        exitSource?.cancel()
        exitSource = nil
        defer { status = nil }
        guard let pid = helperPID else { return }
        // Another app instance took the helper over (an update's new build
        // starts before this one quits): it is no longer this app's to stop.
        if let owner = status?.ownerPID, owner != appPID { return }
        try? channel.write(AutomationHelperRequest(kind: .stop, appPID: appPID), to: channel.requestURL)
        channel.post(channel.requestName)
        guard waitForExit else { return }
        if !wait(timeout: exitTimeout, until: { !self.isAlive(pid) }) { forceQuit(pid) }
    }

    private func terminate(_ helper: AutomationHelperStatus) {
        exitSource?.cancel()
        exitSource = nil
        try? channel.write(AutomationHelperRequest(kind: .stop, appPID: helper.ownerPID), to: channel.requestURL)
        channel.post(channel.requestName)
        if !wait(timeout: exitTimeout, until: { !AutomationHelperChannel.isAlive(helper.pid) }) { forceQuit(helper.pid) }
        _ = wait(timeout: 1, until: { !AutomationHelperChannel.isAlive(helper.pid) })
        status = nil
    }

    private func isAlive(_ pid: Int32) -> Bool {
        if let process, process.processIdentifier == pid { return process.isRunning }
        return AutomationHelperChannel.isAlive(pid)
    }

    private func watch(_ pid: Int32) {
        exitSource?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.helperExited(pid) }
        source.resume()
        exitSource = source
    }

    private func helperExited(_ pid: Int32) {
        guard wanted else { return }
        status = nil
        // Another app instance (an update's new build) has a helper of its
        // own now: this one stands down instead of fighting for the keys.
        if let other = channel.read(AutomationHelperStatus.self, from: channel.statusURL),
           other.pid != pid, other.ownerPID != appPID, AutomationHelperChannel.isAlive(other.pid) {
            wanted = false
            return
        }
        // Bring it back, but not in a loop: five tries a minute.
        respawns = respawns.filter { $0 > Date().addingTimeInterval(-60) }
        guard respawns.count < 5 else {
            wanted = false
            onHelperLost?()
            return
        }
        respawns.append(Date())
        NSLog("BarShelf keyboard helper (pid %d) exited; starting it again", pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.wanted, self.helperPID == nil else { return }
            if !self.spawn() {
                self.wanted = false
                self.onHelperLost?()
            }
        }
    }

    /// Turns the main run loop until `until` holds. Requests are sent from
    /// UI actions, which expect an answer before they return; the helper
    /// answers in milliseconds. The status file is read on every turn, so a
    /// missed notification cannot stall this.
    private func wait(timeout: TimeInterval, until: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !until() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            refresh()
        }
        return true
    }
}
