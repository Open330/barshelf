import AppKit
import MenubucketCore
import SwiftUI

/// Hover, peek and click for the menu bar cluster (`MenuBarLayout.cluster`).
///
/// Everything happens inside the status item's own width. Under the pointer
/// the chip under the pointer grows into a pill with its reading, a gap
/// opening on each side of it (`ClusterGeometry.pillLayout`). The BarShelf
/// icon fades out to make room, and the item takes what else the widest
/// pill needs on its left once, when the pointer arrives, so moving between
/// chips never moves the rest of the menu bar; it gives it back when the
/// pointer leaves. Resting on a chip shows
/// a peek below the bar; clicking runs the widget's click action, and its
/// card hangs off that chip. With a card open, moving to another chip (or
/// pressing ← →) moves the card there.
///
/// What stays true from the rest of the menu bar code:
/// - A closed card lets go of its SwiftUI graph (`PopoverSurface`), and the
///   peek panel drops its hosting view when it hides.
/// - The card is anchored to the status item's button, a view that outlives
///   it; only the positioning rect moves between chips.
final class MenuBarClusterController: NSObject {
    /// A chip was clicked: the owner decides what the widget's click does.
    var onChipClick: ((String) -> Void)?
    /// Right-click on a chip.
    var onChipContextMenu: ((String, NSEvent, NSView) -> Void)?
    /// A widget's colour.
    var chipColor: ((String) -> Color)?

    private let runtime: WidgetRuntime
    private weak var statusItem: NSStatusItem?
    private let menuBar: MenuBarController

    private(set) var chips: [ClusterChip] = []
    private var isEnabled = false
    /// Follows the pointer while the cluster is on. Not a tracking area:
    /// since macOS 26 the menu bar host draws status items, and the app's
    /// own button is a stand-in that receives no hover events and whose
    /// click events carry no real position. The pointer is read in screen
    /// coordinates and compared with the item's frame instead.
    private var pointerWatcher: PointerWatcher?
    private var pointerInside = false

    private var peek: ClusterPeekPanel?
    private var peekWork: DispatchWorkItem?

    private let cardModel = ClusterCardModel()
    private var card: PopoverSurface?
    private var cardWidgetID: String?
    /// The chip whose card is open.
    private var activeIndex: Int?
    private var keyMonitor: Any?
    /// The chip a click landed on, so the card hangs off that chip even when
    /// a widget has more than one (profiles).
    private var pressedIndex: Int?
    /// The widget whose card a mouse-down just closed, and when. A transient
    /// popover closes on the mouse-down; the status item's action comes on the
    /// mouse-up of the same click, which must not open the card again.
    /// Escape or any other close leaves this nil.
    private var closingClick: (widgetID: String, at: Date)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    static let peekDelay: TimeInterval = 0.25
    static let closingClickWindow: TimeInterval = 0.6
    /// Gap between the menu bar and the peek.
    static let peekGap: CGFloat = 4

    init(runtime: WidgetRuntime, statusItem: NSStatusItem, menuBar: MenuBarController) {
        self.runtime = runtime
        self.statusItem = statusItem
        self.menuBar = menuBar
        super.init()
        // A Space switch or a display change leaves a peek or card pointing
        // at nothing.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismiss() }))
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismiss() }))
    }

    deinit {
        removeKeyMonitor()
        pointerWatcher?.stop()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    // MARK: - State from the menu bar

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            installTracking()
        } else {
            dismiss()
            removeTracking()
        }
    }

    func update(_ chips: [ClusterChip]) {
        let previous = self.chips
        self.chips = chips
        updateAccessibility()
        if let cardWidgetID, !chips.contains(where: { $0.widgetID == cardWidgetID }) {
            card?.hide()
            return
        }
        guard previous.map(\.id) != chips.map(\.id) else { return }
        // Chips came or went: keep the card on its widget's chip.
        hidePeek()
        if let cardWidgetID, let button = statusItem?.button,
           let index = chips.firstIndex(where: { $0.widgetID == cardWidgetID }) {
            activeIndex = index
            menuBar.setClusterFocus(index, animated: false)
            card?.reposition(to: menuBar.clusterChipRect(index, in: button))
        }
    }

    /// Everything closed: the shelf is opening, or the layout changed.
    func dismiss() {
        card?.hide()
        hidePeek()
        menuBar.setClusterFocus(nil, animated: false)
    }

    // MARK: - Pointer on the status item

    private func installTracking() {
        guard pointerWatcher == nil else { return }
        pointerWatcher = PointerWatcher { [weak self] in self?.pointerMoved() }
        updateAccessibility()
    }

    private func removeTracking() {
        pointerWatcher?.stop()
        pointerWatcher = nil
        pointerInside = false
        statusItem?.button?.setAccessibilityChildren(nil)
    }

    /// The status item's frame in the menu bar of the screen the pointer is
    /// on. The menu bar host draws the item on every display's menu bar,
    /// while the app's stand-in window knows only one of them. Items sit at
    /// the same distance from each menu bar's right end, so the stand-in's
    /// frame is carried over to the pointer's screen by that distance.
    private func itemFrame(near point: NSPoint) -> NSRect? {
        guard let button = statusItem?.button, let window = button.window,
              let home = window.screen ?? NSScreen.main,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
        else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let fromRight = home.frame.maxX - frame.minX
        let bar = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        return NSRect(
            x: screen.frame.maxX - fromRight, y: screen.frame.maxY - bar,
            width: frame.width, height: bar
        )
    }

    /// Where the pointer is along the button, or nil when it is off the item.
    private func pointerButtonX() -> CGFloat? {
        let point = NSEvent.mouseLocation
        guard let frame = itemFrame(near: point) else { return nil }
        // The menu bar's full height counts, and its top edge too (a pointer
        // pushed against the top of the screen).
        guard point.x >= frame.minX, point.x < frame.maxX,
              point.y >= frame.minY, point.y <= frame.maxY + 1 else { return nil }
        return point.x - frame.minX
    }

    /// The chip under a point in the button, in the layout as it stands.
    private func chipIndex(atButtonX x: CGFloat) -> Int? {
        guard let button = statusItem?.button else { return nil }
        return menuBar.clusterIndex(atButtonX: x, in: button)
    }

    private func pointerLeft() {
        pointerInside = false
        hidePeek()
        // With a card open its chip stays uncovered.
        guard card?.isShown != true else { return }
        menuBar.setClusterFocus(nil, animated: true)
    }

    private func pointerMoved() {
        guard isEnabled, !chips.isEmpty else { return }
        guard let x = pointerButtonX() else {
            if pointerInside { pointerLeft() }
            return
        }
        pointerInside = true
        let index = chipIndex(atButtonX: x)
        guard index != menuBar.clusterFocus else { return }
        hidePeek()
        if let index {
            menuBar.setClusterFocus(index, animated: true)
            if card?.isShown == true {
                // Moving along the chips with a card open moves the card.
                showCard(at: index)
            } else {
                schedulePeek(for: index)
            }
        } else if card?.isShown != true {
            // Over the BarShelf icon: fold, so the icon reads as itself.
            menuBar.setClusterFocus(nil, animated: true)
        }
    }

    /// A left click on the status item. False for the BarShelf icon, which
    /// the owner handles as before (the shelf).
    func handleStatusItemClick(_ event: NSEvent) -> Bool {
        guard isEnabled, !chips.isEmpty, let x = pointerButtonX(),
              let index = chipIndex(atButtonX: x) else { return false }
        hidePeek()
        let id = chips[index].widgetID
        let closing = closingClick
        closingClick = nil
        if let closing, closing.widgetID == id,
           Date().timeIntervalSince(closing.at) < Self.closingClickWindow {
            // This click's mouse-down just closed the card: leave it closed.
            return true
        }
        if cardWidgetID == id, card?.isShown == true {
            card?.hide()
            return true
        }
        pressedIndex = index
        onChipClick?(id)
        return true
    }

    /// A right click on the status item: the chip's menu, or false for the
    /// icon, whose menu the owner shows.
    func handleStatusItemRightClick(_ event: NSEvent) -> Bool {
        guard isEnabled, !chips.isEmpty, let button = statusItem?.button, let x = pointerButtonX(),
              let index = chipIndex(atButtonX: x) else { return false }
        hidePeek()
        card?.hide()
        onChipContextMenu?(chips[index].widgetID, event, button)
        return true
    }

    // MARK: - Peek

    private func schedulePeek(for index: Int) {
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPeek(for: index) }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDelay, execute: work)
    }

    private func showPeek(for index: Int) {
        guard card?.isShown != true, menuBar.clusterFocus == index, chips.indices.contains(index),
              let button = statusItem?.button, let window = button.window
        else { return }
        let chip = chips[index]
        let hosting = NSHostingView(rootView: ClusterPeekView(
            chip: chip, color: chipColor?(chip.widgetID) ?? .accentColor
        ))
        let size = hosting.fittingSize
        // Under the chip on the menu bar the pointer is on.
        let chipRect = menuBar.clusterChipRect(index, in: button)
        let item = itemFrame(near: NSEvent.mouseLocation)
            ?? window.convertToScreen(button.convert(button.bounds, to: nil))
        let rect = NSRect(x: item.minX + chipRect.minX, y: item.minY, width: chipRect.width, height: item.height)
        // The view carries its own margin for the shadow; tuck it up so the
        // card itself sits `peekGap` below the bar.
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - Self.peekGap - size.height + Spacing.s)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? window.screen {
            origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - size.width)
        }
        let panel = peek ?? ClusterPeekPanel()
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        peek = panel
    }

    private func hidePeek() {
        peekWork?.cancel()
        peekWork = nil
        guard let peek else { return }
        peek.orderOut(nil)
        // No hosting view left behind to re-render while hidden.
        peek.contentView = nil
        self.peek = nil
    }

    // MARK: - Card

    /// Opens (or moves) the card for a widget, hung off its chip.
    func openCard(widgetID: String) {
        let pressed = pressedIndex.flatMap { chips.indices.contains($0) && chips[$0].widgetID == widgetID ? $0 : nil }
        pressedIndex = nil
        guard let index = pressed ?? chips.firstIndex(where: { $0.widgetID == widgetID }) else { return }
        menuBar.setClusterFocus(index, animated: false)
        showCard(at: index)
    }

    private func showCard(at index: Int) {
        guard chips.indices.contains(index), let button = statusItem?.button,
              let widget = runtime.widgets.first(where: { $0.id == chips[index].widgetID })
        else { return }
        hidePeek()
        cardModel.widget = widget
        cardWidgetID = widget.id
        activeIndex = index
        runtime.menuBarPopoverWidgetID = widget.id
        // Where the chip will rest once its glide ends.
        let rect = menuBar.clusterChipRect(index, in: button)
        if let card, card.isShown {
            card.reposition(to: rect)
        } else {
            let surface = card ?? makeCard()
            surface.show(relativeTo: rect, of: button)
            installKeyMonitor()
        }
        runtime.refreshMenuBarPopoverIfNeeded(widget)
    }

    private func makeCard() -> PopoverSurface {
        let surface = PopoverSurface(
            rootView: ClusterCardView(model: cardModel, runtime: runtime),
            fitsContent: true,
            closesOnEscape: true
        )
        surface.onHide = { [weak self] in
            guard let self else { return }
            self.removeKeyMonitor()
            if let id = self.cardWidgetID, let event = NSApp.currentEvent,
               event.type == .leftMouseDown {
                self.closingClick = (id, Date())
            }
            if self.runtime.menuBarPopoverWidgetID == self.cardWidgetID {
                self.runtime.menuBarPopoverWidgetID = nil
            }
            self.cardWidgetID = nil
            self.cardModel.widget = nil
            self.activeIndex = nil
            if !self.pointerIsOnItem { self.menuBar.setClusterFocus(nil, animated: true) }
        }
        card = surface
        return surface
    }

    private var pointerIsOnItem: Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let point = button.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return button.bounds.contains(point)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let card = self.card, card.isShown,
                  PopupEventRouting.belongsToPopup(eventWindow: event.window, popupWindow: card.eventWindow),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let active = self.activeIndex
            else { return event }
            let step: Int
            switch Int(event.keyCode) {
            case 123: step = -1
            case 124: step = 1
            default: return event
            }
            let target = active + step
            guard self.chips.indices.contains(target) else { NSSound.beep(); return nil }
            self.menuBar.setClusterFocus(target, animated: true)
            self.showCard(at: target)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Accessibility

    /// One element per chip on the status item, so VoiceOver can reach each
    /// widget and open its card without a pointer.
    private func updateAccessibility() {
        guard isEnabled, let button = statusItem?.button else { return }
        let origin = menuBar.clusterOrigin(in: button)
        let geometry = ClusterGeometry(count: chips.count)
        let elements: [ClusterChipElement] = chips.enumerated().map { index, chip in
            let rect = NSRect(
                x: origin + CGFloat(geometry.collapsedX(index)), y: 0,
                width: CGFloat(ClusterGeometry.collapsedStep), height: button.bounds.height
            )
            let element = ClusterChipElement(widgetID: chip.widgetID, label: chip.spoken, frameInParent: rect, parent: button)
            element.onPress = { [weak self] id in
                self?.pressedIndex = index
                self?.onChipClick?(id)
            }
            return element
        }
        button.setAccessibilityChildren(elements.isEmpty ? nil : elements)
    }
}

/// A chip as VoiceOver sees it on the status item.
private final class ClusterChipElement: NSAccessibilityElement {
    let widgetID: String
    var onPress: ((String) -> Void)?

    init(widgetID: String, label: String, frameInParent: NSRect, parent: NSView) {
        self.widgetID = widgetID
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frameInParent)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(widgetID)
        return true
    }
}

/// The peek's window: below the menu bar, on every Space and over a
/// full-screen app. It never takes the pointer or focus.
private final class ClusterPeekPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
