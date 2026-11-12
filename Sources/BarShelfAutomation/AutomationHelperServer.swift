import AppKit
import Combine
import Foundation
import notify

/// The helper's side of the channel: runs the extension through an ordinary
/// in-process `AutomationController` and answers the app's requests.
package final class AutomationHelperServer {
    private let controller: AutomationController
    private let channel: AutomationHelperChannel
    private let build: String
    private let pid: Int32
    package private(set) var ownerPID: Int32
    private var reply: AutomationHelperStatus.Reply?
    private var lastRequestID: String?
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private var observation: AnyCancellable?

    /// The owner changed (adoption); the process watches the new one.
    package var ownerChanged: ((Int32) -> Void)?
    /// A stop request from the owner was carried out; the process exits.
    package var stopped: (() -> Void)?

    package init(controller: AutomationController, channel: AutomationHelperChannel,
                 ownerPID: Int32, build: String = AutomationHelperChannel.currentBuild,
                 pid: Int32 = getpid()) {
        self.controller = controller
        self.channel = channel
        self.ownerPID = ownerPID
        self.build = build
        self.pid = pid
    }

    deinit { channel.cancel(token) }

    /// Starts the saved extension and begins answering.
    package func start() {
        controller.startAtLaunch()
        // Published values change after `objectWillChange`; write on the
        // next turn, when they have.
        observation = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.publish() }
        }
        token = channel.observe(channel.requestName) { [weak self] in self?.handlePendingRequest() }
        publish()
        // A request written while this process was starting.
        handlePendingRequest()
    }

    package func handlePendingRequest() {
        guard let request = channel.read(AutomationHelperRequest.self, from: channel.requestURL),
              request.id != lastRequestID else { return }
        guard Date().timeIntervalSince(request.sentAt) < AutomationHelperRequest.lifetime else {
            lastRequestID = request.id
            return
        }
        handle(request)
    }

    package func handle(_ request: AutomationHelperRequest) {
        lastRequestID = request.id
        switch request.kind {
        case .adopt:
            adopt(request.appPID)
            reply = .init(id: request.id, ok: true)
        case .apply:
            adopt(request.appPID)
            let ok = request.source.map { controller.apply(source: $0, enabled: true) } ?? false
            reply = .init(id: request.id, ok: ok)
        case .stop:
            // Not ours to obey: a quitting app whose successor already
            // adopted this helper.
            guard request.appPID == ownerPID else { return }
            controller.stopForTermination()
            reply = .init(id: request.id, ok: true)
            observation = nil
            publish(running: false)
            stopped?()
            return
        }
        publish()
    }

    private func adopt(_ appPID: Int32) {
        guard appPID != ownerPID else { return }
        ownerPID = appPID
        ownerChanged?(appPID)
    }

    package func status(running: Bool? = nil) -> AutomationHelperStatus {
        let (inputSource, inputSourceMessage) = AutomationHelperStatus.encode(controller.inputSourceStatus)
        return AutomationHelperStatus(
            pid: pid, ownerPID: ownerPID, build: build,
            isRunning: running ?? controller.isRunning,
            enabled: controller.isEnabledAtLaunch,
            source: controller.source,
            message: controller.message,
            bindings: (running ?? controller.isRunning) ? controller.activeBindings.map {
                .init(keyCode: $0.keyCode, modifiers: $0.modifiers, text: $0.canonicalText)
            } : [],
            inputSource: inputSource, inputSourceMessage: inputSourceMessage,
            reply: reply
        )
    }

    private func publish(running: Bool? = nil) {
        do {
            try channel.write(status(running: running), to: channel.statusURL)
            channel.post(channel.statusName)
        } catch {
            NSLog("BarShelf keyboard helper could not write its status: %@", error.localizedDescription)
        }
    }
}

/// `barshelf-app automation-helper --app-pid <pid>`: the keyboard extension in
/// a process of its own.
///
/// It is the app's own executable, so macOS sees the same code identity and
/// the Accessibility permission the user gave BarShelf covers it. It keeps
/// running if the app crashes, and brings the app back.
package enum AutomationHelperProcess {
    package static let argument = "automation-helper"

    @MainActor
    package static func run(arguments: [String]) -> Never {
        let channel = AutomationHelperChannel.standard
        let appPID = arguments.firstIndex(of: "--app-pid")
            .flatMap { arguments.indices.contains($0 + 1) ? Int32(arguments[$0 + 1]) : nil } ?? 0
        // Only the app starts this; without an app to answer to there is
        // nobody to stop it.
        guard appPID > 0 else { exit(64) }

        // One helper at a time: a second one would register the same keys.
        try? FileManager.default.createDirectory(at: channel.directory, withIntermediateDirectories: true)
        let lock = open(channel.lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }

        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let controller = AutomationController()
        let server = AutomationHelperServer(controller: controller, channel: channel, ownerPID: appPID)
        let supervisor = OwnerSupervisor(server: server)
        let delegate = Delegate(channel: channel, controller: controller)
        application.delegate = delegate
        server.ownerChanged = { supervisor.watch($0) }
        server.stopped = { exit(0) }
        server.start()
        supervisor.watch(appPID)
        withExtendedLifetime((delegate, supervisor, server)) { application.run() }
        exit(0)
    }

    /// The helper carries the app's name, so a quit meant for BarShelf can
    /// land here. Pass it on and go.
    private final class Delegate: NSObject, NSApplicationDelegate {
        private let channel: AutomationHelperChannel
        private let controller: AutomationController

        init(channel: AutomationHelperChannel, controller: AutomationController) {
            self.channel = channel
            self.controller = controller
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            channel.post(channel.quitAppName)
            controller.stopForTermination()
            return .terminateNow
        }
    }

    /// Watches the app. An app that goes away without telling the helper to
    /// stop has crashed or was killed: the helper keeps the keys working and
    /// opens the app again.
    private final class OwnerSupervisor {
        private let server: AutomationHelperServer
        private var source: DispatchSourceProcess?
        private var relaunches: [Date] = []

        init(server: AutomationHelperServer) { self.server = server }

        func watch(_ pid: Int32) {
            source?.cancel()
            source = nil
            guard AutomationHelperChannel.isAlive(pid) else {
                ownerExited(pid)
                return
            }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in self?.ownerExited(pid) }
            source.resume()
            self.source = source
        }

        private func ownerExited(_ pid: Int32) {
            // Give a successor (an update's new build, a manual reopen) a
            // moment to adopt this helper before deciding nobody will.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.server.ownerPID == pid else { return }
                self.relaunchApp()
            }
        }

        private func relaunchApp() {
            // At most three times in ten minutes: an app that crashes on
            // launch must not be reopened forever.
            relaunches = relaunches.filter { $0 > Date().addingTimeInterval(-600) }
            guard relaunches.count < 3 else {
                NSLog("BarShelf keyboard helper: the app keeps exiting; not reopening it again")
                return
            }
            let bundle = Bundle.main.bundleURL
            guard bundle.pathExtension == "app", FileManager.default.fileExists(atPath: bundle.path) else { return }
            relaunches.append(Date())
            NSLog("BarShelf keyboard helper: the app exited without stopping the extension; reopening it")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        }
    }
}
