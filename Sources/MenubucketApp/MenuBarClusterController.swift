import AppKit
import MenubucketCore
import SwiftUI

/// Hover, peek and click for the menu bar cluster (`MenuBarLayout.cluster`).
///
/// The status item only ever draws the folded stack; its length never
/// changes, so nothing else in the menu bar moves. Under the pointer a
/// transparent panel just above the menu bar takes over, with the chips fanned
/// out around the one the pointer is on. Resting on a chip shows a peek;
/// clicking it opens that widget's card, hung off the chip; sliding to another
/// chip moves the card there, and ← → do the same from the keyboard.
///
/// What stays true from the rest of the menu bar code:
/// - A closed card lets go of its SwiftUI graph (`PopoverSurface`), and the
///   strip and peek panels drop their hosting views when they hide: nothing
///   of the cluster keeps re-measuring while it is off screen.
/// - The card's popover is anchored to the strip's container view, which
///   stays put while chips move inside it.
final class MenuBarClusterController: NSObject {
    /// A chip was clicked: the owner decides what the widget's click does.
    var onChipClick: ((String) -> Void)?
    /// The BarShelf icon at the end of the strip was clicked.
    var onMarkClick: (() -> Void)?
    /// Right-click on a chip.
    var onChipContextMenu: ((String, NSEvent, NSView) -> Void)?
    /// Right-click on the icon: the app menu.
    var onMarkContextMenu: ((NSEvent, NSView) -> Void)?
    /// A widget's colour.
    var chipColor: ((String) -> Color)?

    private let runtime: WidgetRuntime
    private weak var statusItem: NSStatusItem?
    private let originInButton: (NSStatusBarButton) -> CGFloat
    private let markImage: () -> NSImage

    private(set) var chips: [ClusterChip] = []
    private var isEnabled = false
    private var trackingArea: NSTrackingArea?

    private let model = ClusterStripModel()
    private var strip: ClusterPanel?
    private var stripView: ClusterStripContainer?
    private var peek: ClusterPanel?
    private var peekWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?

    private let cardModel = ClusterCardModel()
    private var card: PopoverSurface?
    private var cardWidgetID: String?
    private var keyMonitor: Any?
    /// The widget whose card a mouse-down just closed, and that event's
    /// timestamp: the click that closes a transient popover is the same
    /// click that lands on the chip, and it must not open the card again.
    /// Escape or any other close leaves this nil, so the next click opens.
    /// The chip a click landed on, so the card hangs off that chip even when
    /// a widget has more than one.
    private var pressedIndex: Int?
    private var closingClick: (widgetID: String, timestamp: TimeInterval)?

    static let peekDelay: TimeInterval = 0.25
    static let collapseDelay: TimeInterval = 0.18
    /// Gap between the menu bar and the peek.
    static let peekGap: CGFloat = 4

    init(
        runtime: WidgetRuntime,
        statusItem: NSStatusItem,
        originInButton: @escaping (NSStatusBarButton) -> CGFloat,
        markImage: @escaping () -> NSImage
    ) {
        self.runtime = runtime
        self.statusItem = statusItem
        self.originInButton = originInButton
        self.markImage = markImage
        super.init()
    }

    deinit {
        removeKeyMonitor()
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
        defer { updateAccessibility() }
        guard strip != nil else { return }
        if let cardWidgetID, !chips.contains(where: { $0.widgetID == cardWidgetID }) {
            card?.hide()
        }
        guard previous.map(\.id) != chips.map(\.id) else {
            // Same chips, new readings: nothing moves.
            model.chips = chips
            refreshColors()
            return
        }
        // Chips came or went: lay the strip out again around the same chip,
        // and keep the card on its widget.
        let anchorID = previous.indices.contains(model.anchor) ? previous[model.anchor].id : nil
        let anchor = anchorID.flatMap { id in chips.firstIndex { $0.id == id } } ?? min(model.anchor, max(chips.count - 1, 0))
        guard !chips.isEmpty else { dismiss(); return }
        layoutStrip(anchor: anchor)
        if let cardWidgetID, let index = chips.firstIndex(where: { $0.widgetID == cardWidgetID }) {
            model.active = index
            card?.reposition(to: chipRect(index))
        }
    }

    /// Everything closed: the shelf is opening, or the layout changed.
    func dismiss() {
        card?.hide()
        hidePeek()
        collapse(immediately: true)
    }

    // MARK: - Status item tracking

    private func installTracking() {
        guard let button = statusItem?.button, trackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
        updateAccessibility()
    }

    private func removeTracking() {
        if let trackingArea, let button = statusItem?.button {
            button.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        statusItem?.button?.setAccessibilityChildren(nil)
    }

    @objc func mouseEntered(with event: NSEvent) {
        guard isEnabled, !chips.isEmpty, let button = statusItem?.button else { return }
        let x = button.convert(event.locationInWindow, from: nil).x - originInButton(button)
        let geometry = ClusterGeometry(count: chips.count)
        // Over the icon, the strip opens around the last chip, beside it.
        let anchor = geometry.collapsedIndex(at: Double(x)) ?? (x < 0 ? 0 : chips.count - 1)
        expand(anchor: anchor)
    }

    @objc func mouseExited(with event: NSEvent) {}

    /// A click on the status item itself, which only happens when the strip
    /// is not over it (keyboard, VoiceOver, a click faster than the hover).
    /// Returns false for the icon, which the owner handles as before.
    func handleStatusItemClick(_ event: NSEvent) -> Bool {
        guard isEnabled, !chips.isEmpty, let button = statusItem?.button else { return false }
        let x = Double(button.convert(event.locationInWindow, from: nil).x - originInButton(button))
        let geometry = ClusterGeometry(count: chips.count)
        guard let index = geometry.collapsedIndex(at: x) else { return false }
        expand(anchor: index)
        pressedIndex = index
        onChipClick?(chips[index].widgetID)
        return true
    }

    // MARK: - Strip

    private func expand(anchor: Int) {
        collapseWork?.cancel()
        if strip != nil, model.expanded { return }
        guard layoutStrip(anchor: anchor) else { return }
        model.hovered = anchor
        model.markHovered = false
        // Folded first, then fanned on the next pass so the spring runs.
        model.expanded = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.strip != nil else { return }
            self.model.expanded = true
            self.schedulePeek(for: anchor)
        }
    }

    /// Sizes and places the strip's panel for the current chips fanned out
    /// around `anchor`, creating the panel if needed. False when the status
    /// item is not on screen.
    @discardableResult
    private func layoutStrip(anchor: Int) -> Bool {
        guard let button = statusItem?.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main
        else { return false }

        let geometry = ClusterGeometry(count: chips.count)
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let stackX = buttonRect.minX + originInButton(button)
        let span = geometry.expandedSpan(anchor: anchor)
        let pad = Spacing.s
        var lower = CGFloat(min(span.lowerBound, 0))
        var upper = CGFloat(max(span.upperBound, geometry.itemWidth))
        // Keep the fan on screen: push it back from whichever edge it passes.
        var shift: CGFloat = 0
        let minX = screen.frame.minX + pad, maxX = screen.frame.maxX - pad
        if stackX + upper > maxX { shift = maxX - (stackX + upper) }
        if stackX + lower + shift < minX { shift = minX - (stackX + lower) }
        lower = min(lower, lower + shift)
        upper = max(upper, upper + shift)

        let frame = NSRect(
            x: stackX + lower - pad, y: buttonRect.minY,
            width: upper - lower + pad * 2, height: buttonRect.height
        )
        model.chips = chips
        refreshColors()
        model.anchor = anchor
        model.fanShift = shift
        model.originX = stackX - frame.minX
        model.active = cardWidgetID.flatMap { id in chips.firstIndex { $0.widgetID == id } }

        let panel = strip ?? makeStripPanel()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return true
    }

    private func makeStripPanel() -> ClusterPanel {
        let panel = ClusterPanel(interactive: true)
        let container = ClusterStripContainer(controller: self)
        let hosting = NSHostingView(rootView: ClusterStripView(model: model, mark: markImage()))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        hosting.frame = container.bounds
        strip = panel
        stripView = container
        return panel
    }

    private func collapse(immediately: Bool = false) {
        collapseWork?.cancel()
        guard strip != nil else { return }
        guard card?.isShown != true else { return }
        hidePeek()
        model.expanded = false
        model.hovered = nil
        let close = DispatchWorkItem { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.strip?.orderOut(nil)
            // No hosting view left behind to re-render while hidden.
            self.strip?.contentView = nil
            self.strip = nil
            self.stripView = nil
        }
        collapseWork = close
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.3), execute: close)
    }

    private func refreshColors() {
        guard let chipColor else { return }
        model.colors = Dictionary(uniqueKeysWithValues: chips.map { ($0.widgetID, chipColor($0.widgetID)) })
    }

    /// Where the strip is under `x` (strip view coordinates).
    fileprivate enum Target: Equatable { case chip(Int), mark, none }

    fileprivate func target(at x: CGFloat) -> Target {
        let geometry = model.geometry
        let stackX = Double(x - model.originX - model.fanShift)
        if geometry.isOnMark(expandedX: stackX, anchor: model.anchor) { return .mark }
        if let index = geometry.expandedIndex(at: stackX, anchor: model.anchor) { return .chip(index) }
        return .none
    }

    /// A chip's rect in the strip view, for anchoring the card and the peek.
    fileprivate func chipRect(_ index: Int) -> NSRect {
        guard let view = stripView else { return .zero }
        let x = CGFloat(model.geometry.expandedX(index, anchor: model.anchor)) + model.originX + model.fanShift
        return NSRect(x: x, y: 0, width: CGFloat(ClusterGeometry.slot), height: view.bounds.height)
    }

    // MARK: - Pointer in the strip

    fileprivate func pointerMoved(to x: CGFloat) {
        collapseWork?.cancel()
        // Back on the strip while it was folding away: open it again, or its
        // hit testing (fanned positions) would not match what it draws.
        if strip != nil, !model.expanded { model.expanded = true }
        switch target(at: x) {
        case .chip(let index):
            model.markHovered = false
            guard model.hovered != index else { return }
            model.hovered = index
            if card?.isShown == true {
                // Sliding along the strip with a card open moves the card.
                showCard(at: index)
            } else {
                hidePeek()
                schedulePeek(for: index)
            }
        case .mark:
            model.hovered = nil
            model.markHovered = true
            hidePeek()
        case .none:
            model.hovered = nil
            model.markHovered = false
            hidePeek()
        }
    }

    fileprivate func pointerExited() {
        model.hovered = nil
        model.markHovered = false
        hidePeek()
        guard card?.isShown != true else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    fileprivate func pressed(at x: CGFloat, event: NSEvent) {
        hidePeek()
        let closing = closingClick
        closingClick = nil
        switch target(at: x) {
        case .chip(let index):
            let id = chips[index].widgetID
            pressedIndex = index
            if let closing, closing.widgetID == id, closing.timestamp == event.timestamp { return }
            if cardWidgetID == id, card?.isShown == true {
                card?.hide()
                return
            }
            onChipClick?(id)
        case .mark:
            card?.hide()
            collapse(immediately: true)
            onMarkClick?()
        case .none:
            break
        }
    }

    fileprivate func rightPressed(at x: CGFloat, event: NSEvent) {
        hidePeek()
        guard let view = stripView else { return }
        switch target(at: x) {
        case .chip(let index): onChipContextMenu?(chips[index].widgetID, event, view)
        case .mark: onMarkContextMenu?(event, view)
        case .none: break
        }
    }

    // MARK: - Peek

    private func schedulePeek(for index: Int) {
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPeek(for: index) }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDelay, execute: work)
    }

    private func showPeek(for index: Int) {
        guard card?.isShown != true, model.expanded, model.hovered == index,
              chips.indices.contains(index), let stripPanel = strip, let view = stripView
        else { return }
        let chip = chips[index]
        let hosting = NSHostingView(rootView: ClusterPeekView(
            chip: chip, color: chipColor?(chip.widgetID) ?? .accentColor
        ))
        let size = hosting.fittingSize
        let rect = stripPanel.convertToScreen(view.convert(chipRect(index), to: nil))
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - Self.peekGap - size.height + Spacing.s)
        if let screen = stripPanel.screen {
            origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - size.width)
        }
        let panel = peek ?? ClusterPanel(interactive: false)
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
        peek.contentView = nil
        self.peek = nil
    }

    // MARK: - Card

    /// Opens (or moves) the card for a widget, hung off its chip.
    func openCard(widgetID: String) {
        let pressed = pressedIndex.flatMap { chips.indices.contains($0) && chips[$0].widgetID == widgetID ? $0 : nil }
        pressedIndex = nil
        guard let index = pressed ?? chips.firstIndex(where: { $0.widgetID == widgetID }) else { return }
        if strip == nil || !model.expanded { expand(anchor: index) }
        // The strip lays out on the next pass; anchor after it.
        DispatchQueue.main.async { [weak self] in self?.showCard(at: index) }
    }

    private func showCard(at index: Int) {
        guard chips.indices.contains(index), let view = stripView,
              let widget = runtime.widgets.first(where: { $0.id == chips[index].widgetID })
        else { return }
        hidePeek()
        cardModel.widget = widget
        cardWidgetID = widget.id
        model.active = index
        model.hovered = index
        runtime.menuBarPopoverWidgetID = widget.id
        if let card, card.isShown {
            card.reposition(to: chipRect(index))
        } else {
            let surface = card ?? makeCard()
            surface.show(relativeTo: chipRect(index), of: view)
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
            // A transient popover closes on the mouse-down outside it; when
            // that click is on the strip, remember it (see `closingClick`).
            if let id = self.cardWidgetID, let event = NSApp.currentEvent,
               event.type == .leftMouseDown {
                self.closingClick = (id, event.timestamp)
            }
            if self.runtime.menuBarPopoverWidgetID == self.cardWidgetID {
                self.runtime.menuBarPopoverWidgetID = nil
            }
            self.cardWidgetID = nil
            self.cardModel.widget = nil
            self.model.active = nil
            if !(self.stripView?.containsPointer ?? false) { self.collapse() }
        }
        card = surface
        return surface
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let card = self.card, card.isShown,
                  PopupEventRouting.belongsToPopup(eventWindow: event.window, popupWindow: card.eventWindow),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let active = self.model.active
            else { return event }
            let step: Int
            switch Int(event.keyCode) {
            case 123: step = -1
            case 124: step = 1
            default: return event
            }
            let target = active + step
            guard self.chips.indices.contains(target) else { NSSound.beep(); return nil }
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
        let origin = originInButton(button)
        let geometry = ClusterGeometry(count: chips.count)
        let elements: [ClusterChipElement] = chips.enumerated().map { index, chip in
            let rect = NSRect(
                x: origin + CGFloat(geometry.collapsedX(index)), y: 0,
                width: CGFloat(ClusterGeometry.collapsedStep), height: button.bounds.height
            )
            let element = ClusterChipElement(widgetID: chip.widgetID, label: chip.spoken, frameInParent: rect, parent: button)
            element.onPress = { [weak self] id in
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

/// A borderless panel just above the menu bar, on every Space and over a
/// full-screen app's menu bar. It never becomes key, so opening it does not
/// take focus from the app in front.
private final class ClusterPanel: NSPanel {
    init(interactive: Bool) {
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
        ignoresMouseEvents = !interactive
        acceptsMouseMovedEvents = interactive
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The strip's container: takes every mouse event over the strip and
/// reports it in its own coordinates. The SwiftUI drawing inside it does not
/// hit-test.
private final class ClusterStripContainer: NSView {
    weak var controller: MenuBarClusterController?
    private var area: NSTrackingArea?

    init(controller: MenuBarClusterController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var containsPointer: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        self.area = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        controller?.pointerMoved(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.pointerMoved(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.pointerExited()
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if event.modifierFlags.contains(.control) {
            controller?.rightPressed(at: x, event: event)
        } else {
            controller?.pressed(at: x, event: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.rightPressed(at: convert(event.locationInWindow, from: nil).x, event: event)
    }
}
