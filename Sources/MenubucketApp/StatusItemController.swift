import AppKit
import Carbon.HIToolbox
import Combine
import MenubucketCore
import SwiftUI

/// Owns the NSStatusItem, the popup surface, and popup-scoped keyboard handling.
///
/// Follows the file-stack pattern: variable-length status item, single action
/// wired for `[.leftMouseUp, .rightMouseUp]` — left click toggles the popup,
/// right click (or ctrl-click) opens the context menu (Refresh All / Quit).
final class StatusItemController: NSObject {
    private static let statusItemLength: CGFloat = 28

    private var statusItem: NSStatusItem!
    private let runtime = WidgetRuntime()
    private let appPrefs = AppPrefs.shared
    private let pager = PagerState()
    private var popup: PopupSurface!
    /// Draws the live strip into the main item and owns the extra status items
    /// of widgets the user split out.
    private var menuBar: MenuBarController!
    private var keyboardMonitor: Any?
    private var scrollMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    /// Carbon global hotkey (toggles the popup; no accessibility permission).
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?

    /// Two-finger swipe tracking (scroll-wheel phases).
    private enum SwipeAxis {
        case undecided, horizontal, vertical
    }
    private var swipeAxis: SwipeAxis = .undecided
    private var swipeAccumulatedX: CGFloat = 0
    private var consumeMomentum = false

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        // Explicit enablement: with automatic validation AppKit re-enables any
        // item whose target responds to its action, overriding `isEnabled`.
        menu.autoenablesItems = false

        let hubItem = NSMenuItem(
            title: "Open BarShelf…",
            action: #selector(openHub(_:)),
            keyEquivalent: ""
        )
        hubItem.target = self
        menu.addItem(hubItem)

        menu.addItem(menuBarSubmenuItem)

        menu.addItem(.separator())

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
        // Post-install: open the popup and (single-widget case) jump to and
        // highlight the freshly installed widget.
        WidgetInstaller.shared.onOpenPopup = { [weak self] in
            self?.openPopupIfNeeded()
        }
        WidgetInstaller.shared.onReveal = { [weak self] id in
            self?.openPopupIfNeeded()
            self?.runtime.reveal(widgetID: id)
        }
        // barshelf://refresh?widget=<id> — nil id means "refresh all".
        WidgetInstaller.shared.onRefreshRequest = { [weak self] widgetID in
            self?.runtime.handleURLRefreshTrigger(widgetID: widgetID)
        }

        // Register the app's single runtime so runtime-less hub shims work.
        // Construction is guaranteed on the main thread (applicationDidFinishLaunching).
        MainActor.assumeIsolated {
            HubWindowController.shared.register(runtime: runtime)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: Self.statusItemLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageScaling = .scaleProportionallyDown
        }
        menuBar = MenuBarController(mainItem: statusItem)
        menuBar.onSelect = { [weak self] widgetID, button in
            self?.toggleWidgetPopover(for: widgetID, anchoredTo: button)
        }
        menuBar.onContextMenu = { [weak self] event, widgetID, button in
            self?.showWidgetMenu(for: widgetID, with: event, anchoredTo: button)
        }
        runtime.menuBar.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] entries in
                self?.menuBar.apply(entries)
            }
            .store(in: &cancellables)
        appPrefs.$preferences
            .receive(on: RunLoop.main)
            .sink { [weak self] preferences in
                self?.applyStatusSymbol(preferences.menuBarSymbol)
                self?.updateHotkey(preferences)
            }
            .store(in: &cancellables)
        applyStatusSymbol(appPrefs.preferences.menuBarSymbol)
        updateHotkey(appPrefs.preferences)
    }

    deinit {
        removeKeyboardMonitor()
        removeScrollMonitor()
        unregisterHotkey()
        if let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
        }
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

    /// Shows the popup if it is not already visible (post-install reveal).
    /// The card for one promoted widget, hanging off its own status item.
    ///
    /// Clicking a menu bar reading used to open the whole shelf and scroll to
    /// the widget, which is a long way round from "what is this number?". A
    /// status item that shows one widget's value should answer for that widget
    /// when clicked, the way a system monitor's modules each do.
    ///
    /// Clicking the same item again closes it, so the item behaves like a
    /// toggle rather than reopening what is already open.
    private func toggleWidgetPopover(for widgetID: String, anchoredTo button: NSStatusBarButton) {
        if let current = widgetPopover, current.widgetID == widgetID, current.surface.isShown {
            current.surface.hide()
            return
        }
        widgetPopover?.surface.hide()
        guard let widget = runtime.widgets.first(where: { $0.id == widgetID }) else { return }

        let surface = PopoverSurface(
            rootView: MenuBarWidgetPopover(widget: widget, runtime: runtime),
            fitsContent: true
        )
        surface.onHide = { [weak self] in
            if self?.widgetPopover?.widgetID == widgetID { self?.widgetPopover = nil }
        }
        widgetPopover = (widgetID: widgetID, surface: surface)
        // The shelf and a single card should not be open at once.
        if popup.isShown { popup.hide() }
        surface.show(relativeTo: button)
        runtime.refresh(widgetID: widgetID, manual: true)
    }

    private func openPopupIfNeeded() {
        guard !popup.isShown, let button = statusItem.button else { return }
        popup.show(relativeTo: button)
    }

    private func showStatusItemMenu(with event: NSEvent) {
        guard let button = statusItem.button else { return }
        rebuildMenuBarSubmenu()
        NSMenu.popUpContextMenu(statusMenu, with: event, for: button)
    }

    /// "Menu Bar ▸" — the picker for which widgets show a live value.
    ///
    /// It lists the widgets that offer one, checked when they are on the bar.
    /// This is both how a widget sharing the strip (which has no status item of
    /// its own to right-click) gets taken off, and how the feature is found in
    /// the first place, since promotion is off until the user asks for it.
    /// The card currently hanging off a menu bar item, if any.
    private var widgetPopover: (widgetID: String, surface: PopoverSurface)?

    private lazy var menuBarSubmenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Menu Bar", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        item.submenu = submenu
        return item
    }()

    private func rebuildMenuBarSubmenu() {
        guard let submenu = menuBarSubmenuItem.submenu else { return }
        submenu.removeAllItems()

        let candidates = runtime.menuBarCandidates
        guard !candidates.isEmpty else {
            menuBarSubmenuItem.isHidden = true
            return
        }
        menuBarSubmenuItem.isHidden = false

        let shown = runtime.menuBar.promotedWidgetIDs
        let labels = Dictionary(
            runtime.menuBar.entries.map { ($0.widgetID, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        for widget in candidates {
            let isOn = shown.contains(widget.id)
            let value = isOn ? (labels[widget.id] ?? nil) : nil
            let item = NSMenuItem(
                title: value.map { "\(widget.displayName) — \($0)" } ?? widget.displayName,
                action: #selector(toggleMenuBarWidget(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = widget.id
            item.state = isOn ? .on : .off
            item.toolTip = isOn
                ? "Remove \(widget.displayName) from the menu bar"
                : "Show \(widget.displayName) in the menu bar"
            submenu.addItem(item)
        }
    }

    @objc private func toggleMenuBarWidget(_ sender: NSMenuItem) {
        guard let widgetID = sender.representedObject as? String else { return }
        let isOn = runtime.menuBar.promotedWidgetIDs.contains(widgetID)
        runtime.updateMenuBarPlacement(for: widgetID) { $0.enabled = !isOn }
    }

    @objc private func openHub(_ sender: Any?) {
        popup.hide()
        Task { @MainActor in
            HubWindowController.shared.show(runtime: runtime, tab: .widgets)
        }
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

    /// The mark is applied through `MenuBarController` because the main item's
    /// width and title depend on whether a live strip is present.
    private func applyStatusSymbol(_ symbol: String) {
        menuBar.setMainSymbol(symbol)
    }

    // MARK: - Promoted widget menu

    /// Right-click menu of a widget that has its own status item.
    private func showWidgetMenu(
        for widgetID: String, with event: NSEvent, anchoredTo button: NSStatusBarButton
    ) {
        guard let widget = runtime.widgets.first(where: { $0.id == widgetID })
        else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: widget.displayName, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let open = NSMenuItem(
            title: "Show in BarShelf", action: #selector(showPromotedWidget(_:)), keyEquivalent: ""
        )
        open.target = self
        open.representedObject = widgetID
        menu.addItem(open)

        let refresh = NSMenuItem(
            title: "Refresh", action: #selector(refreshPromotedWidget(_:)), keyEquivalent: ""
        )
        refresh.target = self
        refresh.representedObject = widgetID
        menu.addItem(refresh)

        menu.addItem(.separator())

        let merge = NSMenuItem(
            title: "Merge into BarShelf Item",
            action: #selector(mergePromotedWidget(_:)),
            keyEquivalent: ""
        )
        merge.target = self
        merge.representedObject = widgetID
        // Only a widget that can render a label has something to merge into
        // the shared text strip.
        merge.isEnabled = widget.manifest.statusItem?.showsLabel ?? true
        menu.addItem(merge)

        let remove = NSMenuItem(
            title: "Remove from Menu Bar",
            action: #selector(demotePromotedWidget(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        remove.representedObject = widgetID
        menu.addItem(remove)

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func showPromotedWidget(_ sender: NSMenuItem) {
        guard let widgetID = sender.representedObject as? String else { return }
        openPopupIfNeeded()
        runtime.reveal(widgetID: widgetID)
    }

    @objc private func refreshPromotedWidget(_ sender: NSMenuItem) {
        guard let widgetID = sender.representedObject as? String else { return }
        runtime.refresh(widgetID: widgetID, manual: true)
    }

    @objc private func mergePromotedWidget(_ sender: NSMenuItem) {
        guard let widgetID = sender.representedObject as? String else { return }
        runtime.updateMenuBarPlacement(for: widgetID) { $0.separate = false }
    }

    @objc private func demotePromotedWidget(_ sender: NSMenuItem) {
        guard let widgetID = sender.representedObject as? String else { return }
        runtime.updateMenuBarPlacement(for: widgetID) { $0.enabled = false }
    }

    // MARK: - Global hotkey (Carbon RegisterEventHotKey — no a11y permission)

    /// Re-registers the popup hotkey from the current preferences. Called on
    /// every prefs change: unregisters first, then registers only when enabled
    /// and the string parses. Invalid strings fail silently (no hotkey).
    private func updateHotkey(_ preferences: AppPreferences) {
        unregisterHotkey()
        guard preferences.popupHotkeyEnabled,
              let combo = Self.parseHotkey(preferences.popupHotkey)
        else { return }
        registerHotkey(keyCode: combo.keyCode, modifiers: combo.modifiers)
    }

    private func registerHotkey(keyCode: UInt32, modifiers: UInt32) {
        installHotkeyHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4253_5246 /* 'BSRF' */), id: 1
        )
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr {
            hotKeyRef = ref
        }
    }

    private func unregisterHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Installs the single application-wide `kEventHotKeyPressed` handler once;
    /// it forwards presses to `hotkeyPressed()` on the main thread.
    private func installHotkeyHandlerIfNeeded() {
        guard hotKeyEventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let controller = Unmanaged<StatusItemController>
                    .fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { controller.hotkeyPressed() }
                return noErr
            },
            1, &eventType, selfPtr, &hotKeyEventHandler
        )
    }

    fileprivate func hotkeyPressed() {
        togglePopup()
    }

    /// Parses "cmd+shift+b"-style strings: lowercase modifiers (cmd/command,
    /// shift, opt/option/alt, ctrl/control) plus exactly one final key, joined
    /// by "+". Requires at least one modifier and a known key; returns nil on
    /// anything unrecognized (caller then registers no hotkey).
    private static func parseHotkey(_ string: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let tokens = string.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var keyToken: String?
        for token in tokens {
            switch token {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            default:
                if keyToken != nil { return nil } // more than one non-modifier
                keyToken = token
            }
        }
        guard let keyToken, modifiers != 0,
              let keyCode = keyCodes[keyToken]
        else { return nil }
        return (keyCode, modifiers)
    }

    /// ANSI virtual key codes for the keys we accept as a hotkey's final key.
    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34,
        "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "return": 36, "tab": 48,
    ]

    // MARK: - Keyboard (popup-scoped): ←/→ page switch, ⌘1..9 jump, Esc close

    private func installKeyboardMonitor() {
        removeKeyboardMonitor()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.popup.isShown else { return event }
            // Search fields and settings editors own arrows, Escape, and
            // Command-number shortcuts while they are being edited.
            if Self.isTextEditing(event.window?.firstResponder) { return event }
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

    private static func isTextEditing(_ responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView {
            return textView.isEditable || textView.isFieldEditor
        }
        if let textField = responder as? NSTextField {
            return textField.isEditable || textField.isSelectable
        }
        return false
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
