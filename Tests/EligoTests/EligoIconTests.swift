import AppKit
import XCTest
@testable import Eligo

@MainActor
final class EligoIconTests: XCTestCase {
    func testAlwaysShowChooserOnlyAddsMarkerInsideOpenChannelAt1x() throws {
        try assertAlwaysShowChooserOnlyAddsMarker(size: 18, scale: 1, minimumStrongMarkerPixels: 4)
        try assertAlwaysShowChooserOnlyAddsMarker(size: 72, scale: 1, minimumStrongMarkerPixels: 16)
    }

    func testAlwaysShowChooserOnlyAddsMarkerInsideOpenChannelAt2x() throws {
        try assertAlwaysShowChooserOnlyAddsMarker(size: 18, scale: 2, minimumStrongMarkerPixels: 16)
        try assertAlwaysShowChooserOnlyAddsMarker(size: 72, scale: 2, minimumStrongMarkerPixels: 64)
    }

    func test18ptMarkerHasSeparateOpaquePeaksAt1x() throws {
        // At 1x the subpixel gaps may contain antialiasing, but the star and
        // three strokes must still have separate opaque peaks.
        try assert18ptMarkerSeparation(scale: 1, inkThreshold: 0.5)
    }

    func test18ptMarkerHasTransparentGapsAt2x() throws {
        // At 2x the calibrated tips leave an empty pixel above and below the
        // star. This catches the old 0.12-radius marker and tighter branches.
        try assert18ptMarkerSeparation(scale: 2, inkThreshold: 0.001)
    }

    func testAppIconRendersFullColorOpaqueContent() throws {
        let size: CGFloat = 128
        let icon = EligoIcon.appIcon(size: size)

        XCTAssertEqual(icon.size, NSSize(width: size, height: size))
        XCTAssertFalse(icon.isTemplate, "The app icon must stay full-color for the Dock and About window")

        // Smoke only: assert substantial opaque coverage, not visual details —
        // pixel-exact gradient/shadow assertions would test AppKit, not intent.
        let bitmap = try bitmap(for: icon)
        var opaquePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    opaquePixels += 1
                }
            }
        }
        let coverage = Double(opaquePixels) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        XCTAssertGreaterThan(
            coverage,
            0.8,
            "The app icon must render substantial opaque content (coverage: \(coverage))"
        )
    }

    private func assertAlwaysShowChooserOnlyAddsMarker(
        size: CGFloat,
        scale: CGFloat,
        minimumStrongMarkerPixels: Int
    ) throws {
        let disabled = EligoIcon.menuBarIcon(alwaysShowChooser: false, size: size)
        let enabled = EligoIcon.menuBarIcon(alwaysShowChooser: true, size: size)

        XCTAssertEqual(disabled.size, NSSize(width: size, height: size))
        XCTAssertEqual(enabled.size, disabled.size)
        XCTAssertTrue(disabled.isTemplate)
        XCTAssertTrue(enabled.isTemplate)

        let disabledBitmap = try bitmap(for: disabled, scale: scale)
        let enabledBitmap = try bitmap(for: enabled, scale: scale)
        XCTAssertEqual(disabledBitmap.pixelsWide, Int(size * scale))
        XCTAssertEqual(disabledBitmap.pixelsHigh, Int(size * scale))
        XCTAssertEqual(enabledBitmap.pixelsWide, disabledBitmap.pixelsWide)
        XCTAssertEqual(enabledBitmap.pixelsHigh, disabledBitmap.pixelsHigh)
        XCTAssertEqual(alphaBounds(in: enabledBitmap), alphaBounds(in: disabledBitmap))

        // Coupled to menuBarIcon: center (0.70, 0.68), outer radius 0.095.
        // AppKit y increases upward; bitmap rows increase downward, so the
        // star's y range 0.585...0.775 becomes 0.225...0.415. A touched pixel's
        // center can extend half a device pixel beyond the vector bounds.
        // Update these bounds when changing the star, at both 1x and 2x.
        let markerRegion = NSRect(
            x: CGFloat(disabledBitmap.pixelsWide) * 0.605,
            y: CGFloat(disabledBitmap.pixelsHigh) * 0.225,
            width: CGFloat(disabledBitmap.pixelsWide) * 0.19,
            height: CGFloat(disabledBitmap.pixelsHigh) * 0.19
        ).insetBy(dx: -0.5, dy: -0.5)
        var changedPixels = 0
        var changedPixelsOutsideMarker = 0
        var removedPixels = 0
        var strongMarkerPixels = 0

        for y in 0..<disabledBitmap.pixelsHigh {
            for x in 0..<disabledBitmap.pixelsWide {
                let disabledAlpha = disabledBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                let enabledAlpha = enabledBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if enabledAlpha + 0.001 < disabledAlpha {
                    removedPixels += 1
                }
                if enabledAlpha - disabledAlpha >= 0.5 {
                    strongMarkerPixels += 1
                }
                guard abs(disabledAlpha - enabledAlpha) > 0.001 else { continue }

                changedPixels += 1
                if !markerRegion.contains(NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    changedPixelsOutsideMarker += 1
                }
            }
        }

        XCTAssertGreaterThan(changedPixels, 0, "The enabled state must add a visible marker at \(size)pt")
        XCTAssertEqual(removedPixels, 0, "The enabled state must never remove or fade base pixels at \(size)pt")
        XCTAssertGreaterThanOrEqual(
            strongMarkerPixels,
            minimumStrongMarkerPixels,
            "The embedded marker must remain recognizable at \(size)pt"
        )
        XCTAssertEqual(
            changedPixelsOutsideMarker,
            0,
            "The base menu bar glyph must be pixel-identical outside the embedded marker at \(size)pt"
        )
    }

    private func bitmap(for image: NSImage, scale: CGFloat = 1) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width * scale),
            pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size),
                   from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: false, hints: nil)
        return bitmap
    }

    private func assert18ptMarkerSeparation(scale: CGFloat, inkThreshold: CGFloat) throws {
        let image = EligoIcon.menuBarIcon(alwaysShowChooser: true, size: 18)
        let bitmap = try bitmap(for: image, scale: scale)
        // Cross the star's vertical tips, where the two channel gaps are
        // narrowest. This measures rendered ink, not the star's bounding box.
        let x = Int(CGFloat(bitmap.pixelsWide) * 0.70)
        var inkRuns = 0
        var previousPixelHasInk = false
        for y in 0..<bitmap.pixelsHigh {
            let hasInk = (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > inkThreshold
            if hasInk && !previousPixelHasInk { inkRuns += 1 }
            previousPixelHasInk = hasInk
        }
        XCTAssertEqual(inkRuns, 4, "The three strokes and active marker must stay separate at 18pt @\(scale)x")
    }

    private func alphaBounds(in bitmap: NSBitmapImageRep) -> NSRect {
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                guard alpha > 0.001 else { continue }

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return .zero }
        return NSRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }
}
