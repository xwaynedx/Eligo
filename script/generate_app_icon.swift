import AppKit
import Foundation

@main
struct AppIconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: generate_app_icon <iconset-directory>\n", stderr)
            exit(2)
        }

        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for size in [16, 32, 128, 256, 512] {
            try renderIcon(pixels: size, filename: "icon_\(size)x\(size).png", in: outputDirectory)
            try renderIcon(pixels: size * 2, filename: "icon_\(size)x\(size)@2x.png", in: outputDirectory)
        }
    }

    private static func renderIcon(pixels: Int, filename: String, in outputDirectory: URL) throws {
        // Render into an explicit pixel-sized bitmap rep instead of relying on
        // NSImage.lockFocus(), whose backing scale follows the current screen's
        // retina factor. lockFocus() on a 2x context doubles the pixel count, so
        // `pixels: 16` silently produced a 32×32 PNG. actool (Xcode 16+) rejects
        // those as "Ambiguous Content" and emits no Assets.car/AppIcon.icns,
        // breaking `build_and_run.sh --verify`. Pinning the rep to the exact
        // pixel size makes the exported PNG match its filename.
        let size = CGFloat(pixels)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "EligoIcon", code: 1)
        }
        rep.size = NSSize(width: size, height: size)

        let image = EligoIcon.appIcon(size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "EligoIcon", code: 2)
        }
        try pngData.write(to: outputDirectory.appendingPathComponent(filename))
    }
}
