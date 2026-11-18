import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Extracts icons from Windows executables and turns them into macOS-style app icons.
public enum IconTools {
    /// Largest image of the executable's main icon.
    public static func executableIcon(_ url: URL) -> CGImage? {
        guard let pe = PEFile(url: url), let ico = pe.iconFileData(),
              let source = CGImageSourceCreateWithData(ico as CFData, nil) else { return nil }
        var best: CGImage?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if best == nil || image.width > best!.width || (image.width == best!.width && image.bitsPerPixel > best!.bitsPerPixel) {
                best = image
            }
        }
        return best
    }

    public static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @discardableResult
    public static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Saves the app's icon (and Steam artwork) into Cell's icon cache. Returns (iconFile, artworkFile).
    public static func cacheIcons(for app: AppEntry, executable: URL?, artwork: SteamArtwork?) -> (String?, String?) {
        var iconFile: String?
        var artworkFile: String?
        if let executable, let image = executableIcon(executable) {
            let name = "\(app.id.uuidString).png"
            if writePNG(image, to: CellPaths.icons.appendingPathComponent(name)) { iconFile = name }
        }
        if iconFile == nil, let icon = artwork?.icon, let image = loadImage(icon) {
            let name = "\(app.id.uuidString).png"
            if writePNG(image, to: CellPaths.icons.appendingPathComponent(name)) { iconFile = name }
        }
        if let art = artwork?.best {
            let name = "\(app.id.uuidString)-art.\(art.pathExtension.isEmpty ? "jpg" : art.pathExtension)"
            let target = CellPaths.icons.appendingPathComponent(name)
            if (try? FileOps.cloneItem(at: art, to: target)) != nil { artworkFile = name }
        }
        return (iconFile, artworkFile)
    }

    // MARK: macOS icon composition

    /// A 1024×1024 macOS-style icon: rounded square body, soft shadow, artwork or the exe icon.
    public static func composeAppIcon(icon: CGImage?, artwork: CGImage?, title: String) -> CGImage? {
        let size = 1024
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let radius: CGFloat = 185
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Shadow under the body.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        let useArtwork = artwork != nil && (icon == nil || icon!.width < 128)
        if useArtwork, let artwork {
            draw(artwork, filling: body, in: context)
        } else if let icon {
            let tint = averageColor(icon) ?? (0.25, 0.3, 0.4)
            let colors = [CGColor(srgbRed: min(tint.0 * 0.55 + 0.32, 1), green: min(tint.1 * 0.55 + 0.32, 1), blue: min(tint.2 * 0.55 + 0.34, 1), alpha: 1),
                          CGColor(srgbRed: tint.0 * 0.35 + 0.05, green: tint.1 * 0.35 + 0.05, blue: tint.2 * 0.35 + 0.07, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
            }
            let inset = body.insetBy(dx: 150, dy: 150)
            context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: CGColor(gray: 0, alpha: 0.45))
            context.draw(icon, in: inset)
        } else {
            let colors = [CGColor(srgbRed: 0.33, green: 0.38, blue: 0.52, alpha: 1), CGColor(srgbRed: 0.12, green: 0.14, blue: 0.2, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
            }
            drawInitial(title, in: body, context: context)
        }
        // Subtle top highlight.
        let highlight = [CGColor(gray: 1, alpha: 0.16), CGColor(gray: 1, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: highlight, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY), options: [])
        }
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        context.setLineWidth(3)
        context.strokePath()
        return context.makeImage()
    }

    private static func draw(_ image: CGImage, filling rect: CGRect, in context: CGContext) {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        // Portrait capsules keep their top (titles usually sit there); wide headers stay centred.
        let y = image.height > image.width ? rect.maxY - height : rect.midY - height / 2
        context.draw(image, in: CGRect(x: rect.midX - width / 2, y: y, width: width, height: height))
    }

    private static func drawInitial(_ title: String, in rect: CGRect, context: CGContext) {
        let letter = String(title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        let font = CTFontCreateWithName("SF Pro Rounded" as CFString, 440, nil)
        let attributes = [kCTFontAttributeName as String: font,
                          kCTForegroundColorAttributeName as String: CGColor(gray: 1, alpha: 0.92)] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, letter as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX, y: rect.midY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }

    private static func averageColor(_ image: CGImage) -> (CGFloat, CGFloat, CGFloat)? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.1 else { continue }
            r += Double(pixels[i]) / 255
            g += Double(pixels[i + 1]) / 255
            b += Double(pixels[i + 2]) / 255
            weight += alpha
        }
        guard weight > 0 else { return nil }
        return (CGFloat(r / weight), CGFloat(g / weight), CGFloat(b / weight))
    }

    /// Cell's own (placeholder) app icon: a glowing cell doorway with a play mark.
    public static func cellAppIcon() -> CGImage? {
        let size = 1024
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.4))
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.2, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        let background = [CGColor(srgbRed: 0.18, green: 0.2, blue: 0.48, alpha: 1), CGColor(srgbRed: 0.05, green: 0.06, blue: 0.16, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: background, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        }
        // Doorway glow.
        let door = CGRect(x: 300, y: 220, width: 424, height: 560)
        let doorPath = CGPath(roundedRect: door, cornerWidth: 90, cornerHeight: 90, transform: nil)
        let glow = [CGColor(srgbRed: 0.35, green: 0.85, blue: 1, alpha: 0.55), CGColor(srgbRed: 0.35, green: 0.85, blue: 1, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: glow, locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                                       endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])
        }
        context.addPath(doorPath)
        context.setFillColor(CGColor(srgbRed: 0.04, green: 0.05, blue: 0.13, alpha: 0.9))
        context.fillPath()
        context.addPath(doorPath)
        context.setLineWidth(26)
        context.replacePathWithStrokedPath()
        context.clip()
        let rim = [CGColor(srgbRed: 0.4, green: 0.95, blue: 1, alpha: 1), CGColor(srgbRed: 0.62, green: 0.4, blue: 1, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: rim, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 780), end: CGPoint(x: 724, y: 220), options: [])
        }
        context.restoreGState()

        // Play mark.
        context.saveGState()
        context.addPath(path)
        context.clip()
        let play = CGMutablePath()
        play.move(to: CGPoint(x: 462, y: 400))
        play.addLine(to: CGPoint(x: 462, y: 600))
        play.addLine(to: CGPoint(x: 620, y: 500))
        play.closeSubpath()
        context.setShadow(offset: .zero, blur: 30, color: CGColor(srgbRed: 0.4, green: 0.9, blue: 1, alpha: 0.9))
        context.addPath(play)
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fillPath()
        context.restoreGState()
        return context.makeImage()
    }

    /// Writes all standard and Retina representations through an explicitly named iconset.
    /// ImageIO's ICNS encoder can report success while silently dropping 64- and 1024-pixel images.
    public static func writeICNS(_ image: CGImage, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Icon generation also runs during builds, without initializing Cell's user data folders.
        let scratch = fm.temporaryDirectory.appendingPathComponent("cell-icon-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let iconset = scratch.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let png = iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
                guard let scaled = resize(image, to: base * scale), writePNG(scaled, to: png) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: png.path])
                }
            }
        }
        try ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/iconutil"), arguments: ["-c", "icns", iconset.path, "-o", url.path])
    }

    static func resize(_ image: CGImage, to size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}
