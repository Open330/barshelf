import AppKit
import Combine
import MenubucketCore
import SwiftUI

/// Owns the NSStatusItem, the popup surface, and popup-scoped keyboard handling.
///
/// Follows the file-stack pattern: variable-length status item, single action
/// wired for `[.leftMouseUp, .rightMouseUp]` — left click toggles the popup,
/// right click (or ctrl-click) opens the context menu (Refresh All / Quit).
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem!
    private let runtime = WidgetRuntime()
    private let appPrefs = AppPrefs.shared
    private let pager = PagerState()
    private var popup: PopupSurface!
    private var keyboardMonitor: Any?
    private var scrollMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    /// Two-finger swipe tracking (scroll-wheel phases).
    private enum SwipeAxis {
        case undecided, horizontal, vertical
    }
    private var swipeAxis: SwipeAxis = .undecided
    private var swipeAccumulatedX: CGFloat = 0
    private var consumeMomentum = false

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(
            title: "Refresh All",
            action: #selector(refreshAll(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let installItem = NSMenuItem(
            title: "Install Widget from URL…",
            action: #selector(installWidgetFromURL(_:)),
            keyEquivalent: ""
        )
        installItem.target = self
        menu.addItem(installItem)

        let galleryItem = NSMenuItem(
            title: "Widget Gallery…",
            action: #selector(openWidgetGallery(_:)),
            keyEquivalent: ""
        )
        galleryItem.target = self
        menu.addItem(galleryItem)

        let builderItem = NSMenuItem(
            title: "Create Widget…",
            action: #selector(openWidgetBuilder(_:)),
            keyEquivalent: "n"
        )
        builderItem.target = self
        menu.addItem(builderItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit BarShelf",
            action: #selector(terminateApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }()

    override init() {
        super.init()

        let surface = PopoverSurface(rootView: RootView(runtime: runtime, pager: pager))
        surface.onShow = { [weak self] in
            self?.runtime.popupOpened()
            self?.installKeyboardMonitor()
            self?.installScrollMonitor()
        }
        surface.onHide = { [weak self] in
            self?.runtime.popupClosed()
            self?.removeKeyboardMonitor()
            self?.removeScrollMonitor()
            self?.pager.cancelSwipe()
        }
        popup = surface

        // Hot reload covers installs while the watcher is active; the rescan
        // callback covers the first install ever (watch dir absent at launch).
        WidgetInstaller.shared.onInstalled = { [weak self] in
            self?.runtime.loadWidgets()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        appPrefs.$preferences
            .receive(on: RunLoop.main)
            .sink { [weak self] preferences in
                self?.applyStatusSymbol(preferences.menuBarSymbol)
            }
            .store(in: &cancellables)
        applyStatusSymbol(appPrefs.preferences.menuBarSymbol)
    }

    deinit {
        removeKeyboardMonitor()
        removeScrollMonitor()
    }

    // MARK: - Status item events

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopup()
            return
        }

        let isRightClick = event.type == .rightMouseUp
            || event.type == .otherMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isRightClick {
            popup.hide()
            showStatusItemMenu(with: event)
        } else {
            togglePopup()
        }
    }

    private func togglePopup() {
        if popup.isShown {
            popup.hide()
        } else if let button = statusItem.button {
            popup.show(relativeTo: button)
        }
    }

    private func showStatusItemMenu(with event: NSEvent) {
        guard let button = statusItem.button else { return }
        NSMenu.popUpContextMenu(statusMenu, with: event, for: button)
    }

    @objc private func refreshAll(_ sender: Any?) {
        runtime.refreshAll()
    }

    @objc private func installWidgetFromURL(_ sender: Any?) {
        popup.hide()
        WidgetInstaller.shared.promptForURL()
    }

    @objc private func openWidgetGallery(_ sender: Any?) {
        popup.hide()
        Task { @MainActor in
            GalleryWindowController.shared.show()
        }
    }

    @objc func openWidgetBuilder(_ sender: Any?) {
        popup.hide()
        Task { @MainActor in
            WidgetBuilderController.shared.show(runtime: runtime)
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Task { @MainActor in UpdateChecker.check(explicit: true) }
    }

    @objc private func openSettings(_ sender: Any?) {
        popup.hide()
        Task { @MainActor in
            AppSettingsWindowController.shared.show(
                runtime: runtime, appPrefs: appPrefs
            )
        }
    }

    @objc private func terminateApp(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func applyStatusSymbol(_ symbol: String) {
        let fallback = AppPreferences.defaultMenuBarSymbol
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = NSImage(
            systemSymbolName: trimmed.isEmpty ? fallback : trimmed,
            accessibilityDescription: "BarShelf"
        ) ?? NSImage(
            systemSymbolName: fallback,
            accessibilityDescription: "BarShelf"
        )
        statusItem.button?.image = image
    }

    // MARK: - Keyboard (popup-scoped): ←/→ page switch, ⌘1..9 jump, Esc close

    private func installKeyboardMonitor() {
        removeKeyboardMonitor()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.popup.isShown else { return event }
            let pageCount = self.runtime.pages.count

            switch event.keyCode {
            case 123: // ←
                self.pager.step(-1, pageCount: pageCount)
                return nil
            case 124: // →
                self.pager.step(1, pageCount: pageCount)
                return nil
            case 53: // Esc
                self.popup.hide()
                return nil
            default:
                break
            }

            if event.modifierFlags.contains(.command),
               let characters = event.charactersIgnoringModifiers,
               let digit = Int(characters), (1...9).contains(digit) {
                self.pager.jump(to: digit - 1, pageCount: pageCount)
                return nil
            }

            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    // MARK: - Trackpad swipe (popup-scoped): two-finger horizontal → pager

    /// Local scrollWheel monitor. Gesture-phase events are classified once per
    /// gesture by axis dominance: horizontal gestures drive the pager (and are
    /// consumed), vertical gestures pass through to the page's ScrollView.
    /// Legacy mouse-wheel events (no phases) always pass through.
    private func installScrollMonitor() {
        removeScrollMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, self.popup.isShown else { return event }
            return self.handleScrollEvent(event)
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        let pageCount = runtime.pages.count
        let phase = event.phase
        let momentumPhase = event.momentumPhase

        // Momentum tail after the fingers lifted: swallow it for horizontal
        // gestures so it does not bleed into the vertical ScrollView.
        if phase == [] && momentumPhase != [] {
            if consumeMomentum {
                if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
                    consumeMomentum = false
                }
                return nil
            }
            return event
        }

        // Legacy mouse wheel (no gesture phases): vertical scrolling only.
        if phase == [] && momentumPhase == [] {
            return event
        }

        if phase.contains(.began) {
            swipeAxis = .undecided
            swipeAccumulatedX = 0
            consumeMomentum = false
            return event // deltas are usually 0 here; let ScrollView see it
        }

        if phase.contains(.changed) {
            if swipeAxis == .undecided {
                let dx = abs(event.scrollingDeltaX)
                let dy = abs(event.scrollingDeltaY)
                guard dx + dy > 0.5 else { return event } // too small to judge
                if dx > dy, pageCount > 1 {
                    swipeAxis = .horizontal
                    pager.beginSwipe()
                } else {
                    swipeAxis = .vertical
                }
            }
            switch swipeAxis {
            case .horizontal:
                swipeAccumulatedX += event.scrollingDeltaX
                pager.updateSwipe(totalDeltaX: swipeAccumulatedX, pageCount: pageCount)
                return nil
            case .vertical, .undecided:
                return event
            }
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            defer {
                swipeAxis = .undecided
                swipeAccumulatedX = 0
            }
            if swipeAxis == .horizontal {
                if phase.contains(.cancelled) {
                    pager.cancelSwipe()
                } else {
                    pager.endSwipe(pageCount: pageCount)
                }
                consumeMomentum = true
                return nil
            }
            return event
        }

        return event
    }
}
