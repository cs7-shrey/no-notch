import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = WallpaperManager()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Hide Notch", action: #selector(toggleEnabled), keyEquivalent: "")
    private let cornersItem = NSMenuItem(title: "Rounded Corners", action: #selector(toggleCorners), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.tophalf.inset.filled", accessibilityDescription: "NoNotch")

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        for item in [enabledItem, cornersItem, loginItem] { item.target = self }
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.items = [
            statusLine, .separator(),
            enabledItem, cornersItem, loginItem, .separator(),
            refresh,
            NSMenuItem(title: "Quit NoNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        statusItem.menu = menu

        manager.onStatusChange = { [weak self] in self?.updateMenu() }
        manager.start()

        // Register at login on first run; the user can turn it off from the menu.
        if !UserDefaults.standard.bool(forKey: "didOfferLogin") {
            UserDefaults.standard.set(true, forKey: "didOfferLogin")
            try? SMAppService.mainApp.register()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }

    private func updateMenu() {
        let screens = manager.notchedScreenNames
        if let error = manager.lastError {
            statusLine.title = "⚠︎ \(error)"
        } else if screens.isEmpty {
            statusLine.title = "No notched display"
        } else {
            statusLine.title = manager.enabled ? "Active on \(screens.joined(separator: ", "))" : "Paused"
        }
        enabledItem.state = manager.enabled ? .on : .off
        cornersItem.state = manager.roundCorners ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleEnabled() { manager.enabled.toggle(); updateMenu() }
    @objc private func toggleCorners() { manager.roundCorners.toggle(); updateMenu() }
    @objc private func refreshNow() { manager.refresh() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        updateMenu()
    }
}
