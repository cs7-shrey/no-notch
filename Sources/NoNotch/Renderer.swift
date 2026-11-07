import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// How the source image is laid out on the screen, mirroring the user's wallpaper setting.
enum Placement: String, Codable {
    case fill, fit, center

    init(options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        let scaling = (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        switch NSImageScaling(rawValue: scaling) {
        // Axes-independent is what NoNotch itself sets, and it lingers when a wallpaper is changed
        // programmatically. Treating it as fill avoids distorting the next image.
        case .scaleNone: self = .center
        default: self = clipping ? .fill : .fit
        }
    }
}

/// Everything that determines the rendered output. Its `key` changes whenever the output would.
struct RenderSpec {
    var pixelWidth: Int
    var pixelHeight: Int
    var barHeight: Int
    var cornerRadius: Int
    var placement: Placement
    var fillColor: [CGFloat]  // sRGB RGBA, used behind letterboxed images

    init(screen: NSScreen, roundCorners: Bool, options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        let scale = screen.backingScaleFactor
        pixelWidth = Int((screen.frame.width * scale).rounded())
        pixelHeight = Int((screen.frame.height * scale).rounded())
        barHeight = Int((screen.menuBarHeight * scale).rounded(.up))
        cornerRadius = roundCorners ? Int((NSScreen.desktopCornerRadius * scale).rounded()) : 0
        placement = Placement(options: options)
        // Options can be empty; plain NSColor.black has no RGB components, so default explicitly.
        if let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
            fillColor = [color.redComponent, color.greenComponent, color.blueComponent, 1]
        } else {
            fillColor = [0, 0, 0, 1]
        }
    }

    var key: String {
        let fill = fillColor.map { String(format: "%.3f", $0) }.joined(separator: ",")
        return "v1-\(pixelWidth)x\(pixelHeight)-bar\(barHeight)-r\(cornerRadius)-\(placement.rawValue)-\(fill)"
    }
}

enum RenderError: Error, CustomStringConvertible {
    case unreadable(URL), drawFailed, writeFailed(URL)

    var description: String {
        switch self {
        case .unreadable(let url): return "cannot read image at \(url.path)"
        case .drawFailed: return "failed to draw wallpaper"
        case .writeFailed(let url): return "failed to write \(url.path)"
        }
    }
}

enum Renderer {
    /// Stable output name for a source file + spec, so re-visiting a wallpaper reuses the cached render.
    static func outputName(source: URL, spec: RenderSpec) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let digest = SHA256.hash(data: Data("\(source.path)|\(mtime)|\(size)|\(spec.key)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
    }

    static func render(source: URL, spec: RenderSpec, to output: URL) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw RenderError.unreadable(source) }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let srcW = (props[kCGImagePropertyPixelWidth] as? Int) ?? spec.pixelWidth
        let srcH = (props[kCGImagePropertyPixelHeight] as? Int) ?? spec.pixelHeight
        // Thumbnail API applies EXIF orientation; max size = full resolution so nothing is lost.
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(srcW, srcH),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, index, thumbOpts as CFDictionary) else {
            throw RenderError.unreadable(source)
        }

        let w = spec.pixelWidth, h = spec.pixelHeight
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RenderError.drawFailed
        }
        ctx.interpolationQuality = .high
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(srgbRed: spec.fillColor[0], green: spec.fillColor[1], blue: spec.fillColor[2], alpha: 1))
        ctx.fill(full)
        ctx.draw(image, in: imageRect(imageSize: CGSize(width: image.width, height: image.height), in: full, placement: spec.placement))

        // Black bar behind the menu bar. CG origin is bottom-left, so the bar sits at the top of the context.
        let barBottom = CGFloat(h - spec.barHeight)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: barBottom, width: CGFloat(w), height: CGFloat(spec.barHeight)))

        // Concave corners under the bar so the visible desktop looks like it has rounded top corners.
        let r = CGFloat(spec.cornerRadius)
        if r > 0 {
            let left = CGMutablePath()
            left.move(to: CGPoint(x: 0, y: barBottom))
            left.addLine(to: CGPoint(x: 0, y: barBottom - r))
            left.addArc(center: CGPoint(x: r, y: barBottom - r), radius: r, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
            left.closeSubpath()
            let right = CGMutablePath()
            right.move(to: CGPoint(x: CGFloat(w), y: barBottom))
            right.addLine(to: CGPoint(x: CGFloat(w), y: barBottom - r))
            right.addArc(center: CGPoint(x: CGFloat(w) - r, y: barBottom - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
            right.closeSubpath()
            ctx.addPath(left)
            ctx.addPath(right)
            ctx.fillPath()
        }

        guard let result = ctx.makeImage() else { throw RenderError.drawFailed }
        let tmp = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.writeFailed(tmp)
        }
        CGImageDestinationAddImage(dest, result, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.writeFailed(tmp) }
        _ = try FileManager.default.replaceItemAt(output, withItemAt: tmp)
    }

    private static func imageRect(imageSize: CGSize, in bounds: CGRect, placement: Placement) -> CGRect {
        let sx = bounds.width / imageSize.width, sy = bounds.height / imageSize.height
        let scale: CGFloat
        switch placement {
        case .fill: scale = max(sx, sy)
        case .fit: scale = min(sx, sy)
        case .center: scale = 1
        }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 }

    /// Radius of the black concave corners under the bar. macOS 27 windows use ~17.5pt continuous
    /// corners; a 21pt circle is the smallest that hides the wallpaper behind a maximized window's corners.
    static let desktopCornerRadius: CGFloat = 21

    /// Height to blacken: the notch area, or the menu bar if it is taller.
    var menuBarHeight: CGFloat {
        max(safeAreaInsets.top, frame.maxY - visibleFrame.maxY)
    }
}
