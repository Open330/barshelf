import AppKit
import ApplicationServices

/// Geometry uses Quartz / Accessibility coordinates (origin at primary-screen
/// top-left), never AppKit's bottom-left coordinates.
enum AutomationGeometry {
    static func quartz(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func movedFrame(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return frame }
        let width = min(target.width, max(1, frame.width / source.width * target.width))
        let height = min(target.height, max(1, frame.height / source.height * target.height))
        let x = target.minX + (frame.minX - source.minX) / source.width * target.width
        let y = target.minY + (frame.minY - source.minY) / source.height * target.height
        return CGRect(x: min(max(x, target.minX), target.maxX - width),
                      y: min(max(y, target.minY), target.maxY - height), width: width, height: height)
    }

    static func screenIndex(for frame: CGRect, screens: [CGRect]) -> Int? {
        screens.indices.max { a, b in area(frame.intersection(screens[a])) < area(frame.intersection(screens[b])) }
    }
    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    static func nextWindow(current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 1 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        return (current + (forward ? 1 : count - 1)) % count
    }
}

final class AutomationWindows {
    struct Display {
        let name: String
        let id: UInt32
        let frame: CGRect
        let usable: CGRect
    }
    private struct Window {
        let element: AXUIElement
        let pid: pid_t
        let id: Int
        let frame: CGRect
        let title: String
    }
    private var identities: [(AXUIElement, Int)] = []
    private var nextID = 1

    static var displays: [Display] {
        let screens = NSScreen.screens
        let height = screens.first?.frame.height ?? 0
        return screens.map {
            Display(name: $0.localizedName,
                    id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                    frame: AutomationGeometry.quartz($0.frame, primaryHeight: height),
                    usable: AutomationGeometry.quartz($0.visibleFrame, primaryHeight: height))
        }
    }

    func moveMouse(to number: Int) throws {
        guard let display = Self.displays[safe: number - 1] else { return }
        warp(to: display.frame)
        if let window = visibleWindows().first(where: { screen(of: $0)?.id == display.id && !$0.title.isEmpty }) {
            try focus(window)
        }
    }

    func moveWindow(to number: Int) throws {
        guard let target = Self.displays[safe: number - 1], let window = focusedWindow(),
              let source = screen(of: window) else { return }
        if attribute(window.element, "AXFullScreen") as? Bool == true {
            throw AutomationFailure("Exit full screen before moving this window.")
        }
        let frame = AutomationGeometry.movedFrame(window.frame, from: source.usable, to: target.usable)
        var size = frame.size
        var point = frame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let position = AXValueCreate(.cgPoint, &point) else { return }
        // Resize before and after positioning: some apps constrain size to the
        // old display until the origin has moved onto the destination display.
        _ = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        try checked(AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, position), "move window")
        try checked(AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue), "resize window")
    }

    func rotate(forward: Bool) throws {
        guard let current = focusedWindow(), let display = screen(of: current) else { return }
        let windows = visibleWindows().filter { screen(of: $0)?.id == display.id && !$0.title.isEmpty }
            .sorted {
                if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
                if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
                return $0.id < $1.id
            }
        let index = windows.firstIndex { CFEqual($0.element, current.element) }
        guard let next = AutomationGeometry.nextWindow(current: index, count: windows.count, forward: forward) else { return }
        try focus(windows[next])
        warp(to: windows[next].frame)
    }

    private func screen(of window: Window) -> Display? {
        let displays = Self.displays
        guard let index = AutomationGeometry.screenIndex(for: window.frame, screens: displays.map(\.frame)) else { return nil }
        return displays[index]
    }
    private func warp(to frame: CGRect) {
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }
    private func focus(_ window: Window) throws {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        _ = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [.activateIgnoringOtherApps])
        try checked(AXUIElementPerformAction(window.element, kAXRaiseAction as CFString), "focus window")
    }
    private func checked(_ error: AXError, _ action: String) throws {
        guard error == .success else {
            throw AutomationFailure("Could not \(action) (Accessibility error \(error.rawValue)). The app may not support this operation.")
        }
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func focusedWindow() -> Window? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let value = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return describe(unsafeBitCast(value, to: AXUIElement.self), pid: app.processIdentifier)
    }
    private func describe(_ element: AXUIElement, pid: pid_t) -> Window? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        let id: Int
        if let item = identities.first(where: { CFEqual($0.0, element) }) { id = item.1 }
        else {
            id = nextID
            nextID += 1
            identities.append((element, id))
        }
        return Window(element: element, pid: pid, id: id, frame: CGRect(origin: point, size: size),
                      title: attribute(element, kAXTitleAttribute) as? String ?? "")
    }

    private func visibleWindows() -> [Window] {
        // Quartz supplies front-to-back order without needing screen capture.
        // Read titles via AX, since Quartz redacts titles without screen recording permission.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var byPID: [pid_t: [Window]] = [:]
        var ordered: [Window] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { continue }
            if byPID[pid] == nil {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
                byPID[pid] = windows.filter {
                    attribute($0, kAXMinimizedAttribute) as? Bool != true &&
                    attribute($0, kAXRoleAttribute) as? String == kAXWindowRole
                }.compactMap { describe($0, pid: pid) }
            }
            // Public AX doesn't expose a CGWindowID. Match bounds within one
            // point and remove each match so equal-frame windows stay distinct.
            if let index = byPID[pid]?.firstIndex(where: {
                abs($0.frame.minX - x) < 1 && abs($0.frame.minY - y) < 1 &&
                abs($0.frame.width - w) < 1 && abs($0.frame.height - h) < 1
            }), let window = byPID[pid]?.remove(at: index) { ordered.append(window) }
        }
        identities.removeAll { entry in !ordered.contains { CFEqual($0.element, entry.0) } }
        return ordered
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
