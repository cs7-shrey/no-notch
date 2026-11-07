import AppKit

/// Black strip drawn just above the wallpaper, behind the menu bar. Used for wallpapers that
/// can't be re-rendered as an image (Aerials and other live/dynamic system wallpapers).
final class OverlayController {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    func show(on screen: NSScreen, roundCorners: Bool) {
        guard let id = screen.displayID else { return }
        let height = screen.menuBarHeight
        let radius: CGFloat = roundCorners ? NSScreen.desktopCornerRadius : 0
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height - radius,
                           width: screen.frame.width, height: height + radius)

        let window = windows[id] ?? makeWindow()
        windows[id] = window
        if window.frame != frame { window.setFrame(frame, display: false) }
        if let view = window.contentView as? StripView, view.barHeight != height || view.radius != radius {
            view.barHeight = height
            view.radius = radius
            view.needsDisplay = true
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide(on id: CGDirectDisplayID) {
        windows.removeValue(forKey: id)?.orderOut(nil)
    }

    /// Hides strips for displays that are gone or no longer need one.
    func hideAll(except keep: Set<CGDirectDisplayID> = []) {
        for id in windows.keys where !keep.contains(id) { hide(on: id) }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // One level above the wallpaper: under desktop icons, app windows and the menu bar.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = StripView()
        return window
    }
}

private final class StripView: NSView {
    var barHeight: CGFloat = 0
    var radius: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        let barBottom = bounds.maxY - barHeight
        NSRect(x: 0, y: barBottom, width: bounds.width, height: barHeight).fill()
        guard radius > 0 else { return }
        // Concave corners under the bar, same shape as the rendered-wallpaper version.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: barBottom))
        path.line(to: NSPoint(x: 0, y: barBottom - radius))
        path.appendArc(withCenter: NSPoint(x: radius, y: barBottom - radius), radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        path.close()
        path.move(to: NSPoint(x: bounds.maxX, y: barBottom))
        path.line(to: NSPoint(x: bounds.maxX, y: barBottom - radius))
        path.appendArc(withCenter: NSPoint(x: bounds.maxX - radius, y: barBottom - radius), radius: radius, startAngle: 0, endAngle: 90, clockwise: false)
        path.close()
        path.fill()
    }
}
