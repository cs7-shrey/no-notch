import AppKit

/// Remembers which original wallpaper each rendered file came from, so it can be restored.
final class Store {
    struct Entry: Codable {
        var original: URL
        var specKey: String
        var scaling: UInt
        var allowClipping: Bool
        var fillColor: [CGFloat]?
        var lastUsed: Date

        var originalOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
            var opts: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSNumber(value: scaling),
                .allowClipping: NSNumber(value: allowClipping),
            ]
            if let c = fillColor, c.count == 4 {
                opts[.fillColor] = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
            }
            return opts
        }
    }

    let directory: URL
    private let indexURL: URL
    private var entries: [String: Entry] = [:]  // keyed by rendered file name

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("NoNotch/rendered", isDirectory: true)
        indexURL = support.appendingPathComponent("NoNotch/index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func isRendered(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path
    }

    func entry(for rendered: URL) -> Entry? { entries[rendered.lastPathComponent] }

    func record(rendered: URL, original: URL, specKey: String, options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
        var scaling = (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        var clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        // Never restore NoNotch's own stretch setting onto an original image (see Placement).
        if scaling == NSImageScaling.scaleAxesIndependently.rawValue {
            scaling = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            clipping = true
        }
        entries[rendered.lastPathComponent] = Entry(
            original: original,
            specKey: specKey,
            scaling: scaling,
            allowClipping: clipping,
            fillColor: color.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] },
            lastUsed: Date()
        )
        save()
    }

    func touch(_ rendered: URL) {
        guard entries[rendered.lastPathComponent] != nil else { return }
        entries[rendered.lastPathComponent]?.lastUsed = Date()
        save()
    }

    /// Deletes renders unused for 30 days, unless one is currently set as a wallpaper.
    func prune(keeping inUse: Set<String>) {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for (name, entry) in entries where entry.lastUsed < cutoff && !inUse.contains(name) {
            entries[name] = nil
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where entries[file] == nil && !inUse.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
