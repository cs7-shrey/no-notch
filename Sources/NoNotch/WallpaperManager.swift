import AppKit
import os

private let log = Logger(subsystem: "dev.nonotch.NoNotch", category: "wallpaper")

/// Keeps every notched screen's wallpaper swapped for a copy with a black menu bar band.
///
/// It only uses public NSWorkspace wallpaper APIs, which apply to the current Space. Each time
/// a Space becomes active (or the wallpaper changes) the current wallpaper is checked and
/// replaced if needed. Polling covers changes macOS doesn't announce, like picking a new image.
final class WallpaperManager {
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled"); refresh() }
    }
    var roundCorners: Bool {
        didSet { UserDefaults.standard.set(roundCorners, forKey: "roundCorners"); refresh() }
    }
    /// Called on the main thread whenever status text should be redrawn.
    var onStatusChange: (() -> Void)?
    private(set) var lastError: String? { didSet { onStatusChange?() } }

    private let store = Store()
    private let overlay = OverlayController()
    private let renderQueue = DispatchQueue(label: "dev.nonotch.render", qos: .userInitiated)
    private var inFlight = Set<CGDirectDisplayID>()
    /// Wallpaper reads can lag 15s+ after a write on macOS 27; don't re-apply during that window.
    private var recentlyApplied: [CGDirectDisplayID: (original: URL, at: Date)] = [:]
    /// Sources that failed to render, with the time, so a bad file isn't retried every poll.
    private var failures: [URL: Date] = [:]
    private var timer: Timer?

    init() {
        UserDefaults.standard.register(defaults: ["enabled": true, "roundCorners": true])
        enabled = UserDefaults.standard.bool(forKey: "enabled")
        roundCorners = UserDefaults.standard.bool(forKey: "roundCorners")
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.5
        store.prune(keeping: currentRenderedNames())
        refresh()
    }

    var notchedScreenNames: [String] {
        NSScreen.screens.filter(\.hasNotch).map(\.localizedName)
    }

    func refresh() {
        overlay.hideAll(except: Set(NSScreen.screens.compactMap(\.displayID)))
        for screen in NSScreen.screens {
            update(screen)
        }
    }

    /// Puts every screen back to its original wallpaper (current Space only).
    func restoreAll() {
        for screen in NSScreen.screens {
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen),
                  store.isRendered(current), let entry = store.entry(for: current) else { continue }
            restore(entry, on: screen)
        }
    }

    private func update(_ screen: NSScreen) {
        guard let id = screen.displayID, !inFlight.contains(id),
              let current = NSWorkspace.shared.desktopImageURL(for: screen) else { return }

        // Aerials and other live wallpapers have no image to re-render; cover the bar instead.
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        if Self.isLiveWallpaper(current, options: options) {
            if enabled && screen.hasNotch {
                overlay.show(on: screen, roundCorners: roundCorners)
            } else {
                overlay.hide(on: id)
            }
            return
        }
        overlay.hide(on: id)

        if store.isRendered(current) {
            guard let entry = store.entry(for: current) else { return }
            if !enabled || !screen.hasNotch {
                restore(entry, on: screen)
            } else if entry.specKey != spec(for: screen, options: entry.originalOptions).key {
                // Settings or resolution changed since this was rendered.
                apply(original: entry.original, options: entry.originalOptions, to: screen)
            }
            return
        }

        guard enabled, screen.hasNotch else { return }
        if let recent = recentlyApplied[id], recent.original == current, Date().timeIntervalSince(recent.at) < 60 { return }
        if let failedAt = failures[current], Date().timeIntervalSince(failedAt) < 60 { return }
        apply(original: current, options: options, to: screen)
    }

    /// For non-image wallpapers (Aerials, the dynamic system default), macOS reports this
    /// placeholder file with no placement options. A real image always comes with options.
    private static func isLiveWallpaper(_ url: URL, options: [NSWorkspace.DesktopImageOptionKey: Any]) -> Bool {
        url.path == "/System/Library/CoreServices/DefaultDesktop.heic" && options.isEmpty
    }

    private func spec(for screen: NSScreen, options: [NSWorkspace.DesktopImageOptionKey: Any]) -> RenderSpec {
        RenderSpec(screen: screen, roundCorners: roundCorners, options: options)
    }

    private func apply(original: URL, options: [NSWorkspace.DesktopImageOptionKey: Any], to screen: NSScreen) {
        guard let id = screen.displayID else { return }
        let spec = spec(for: screen, options: options)
        let output = store.directory.appendingPathComponent(Renderer.outputName(source: original, spec: spec))
        inFlight.insert(id)

        renderQueue.async { [store] in
            var error: Error?
            if !FileManager.default.fileExists(atPath: output.path) {
                do { try Renderer.render(source: original, spec: spec, to: output) } catch let e { error = e }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight.remove(id)
                if let error {
                    log.error("render failed: \(String(describing: error), privacy: .public)")
                    self.failures[original] = Date()
                    self.lastError = "Couldn't process \(original.lastPathComponent)"
                    return
                }
                // The screen set may have changed while rendering.
                guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
                do {
                    try NSWorkspace.shared.setDesktopImageURL(output, for: screen, options: [
                        .imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
                        .allowClipping: NSNumber(value: true),
                    ])
                    store.record(rendered: output, original: original, specKey: spec.key, options: options)
                    self.recentlyApplied[id] = (original, Date())
                    self.lastError = nil
                    log.info("applied \(output.lastPathComponent, privacy: .public) for \(original.path, privacy: .public)")
                } catch {
                    log.error("set wallpaper failed: \(error.localizedDescription, privacy: .public)")
                    self.lastError = "Couldn't set wallpaper: \(error.localizedDescription)"
                }
            }
        }
    }

    private func restore(_ entry: Store.Entry, on screen: NSScreen) {
        guard FileManager.default.fileExists(atPath: entry.original.path) else {
            lastError = "Original wallpaper \(entry.original.lastPathComponent) no longer exists"
            return
        }
        do {
            try NSWorkspace.shared.setDesktopImageURL(entry.original, for: screen, options: entry.originalOptions)
            if let id = screen.displayID { recentlyApplied[id] = nil }
            log.info("restored \(entry.original.path, privacy: .public)")
        } catch {
            lastError = "Couldn't restore wallpaper: \(error.localizedDescription)"
        }
    }

    private func currentRenderedNames() -> Set<String> {
        Set(NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            .filter(store.isRendered).map(\.lastPathComponent))
    }
}
