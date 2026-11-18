import AppKit

enum EligoIcon {
    static func appIcon(size: CGFloat = 128) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let background = NSBezierPath(
            roundedRect: rect,
            xRadius: size * 0.18,
            yRadius: size * 0.18
        )
        NSColor(red: 0.83, green: 0.79, blue: 0.94, alpha: 1).setFill()
        background.fill()
        drawRoutingE(
            in: rect,
            color: NSColor(red: 0.13, green: 0.09, blue: 0.42, alpha: 1),
            lineWidth: size * 0.086,
            branchHeight: 0.28
        )

        image.unlockFocus()
        return image
    }

    static func menuBarIcon(alwaysShowChooser: Bool = false, size: CGFloat = 18) -> NSImage {
        // Keep the source vector-based: rasterize at the destination scale,
        // rather than capturing the host screen's scale with lockFocus().
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Taller branches open up the channels to the right of the junction.
            drawRoutingE(
                in: rect,
                color: .black,
                lineWidth: size * 0.095,
                branchHeight: 0.36
            )

            if alwaysShowChooser {
                // The upper channel holds the active-state marker. Its small-size
                // separation is checked at both 1x and 2x in EligoIconTests.
                let star = fourPointStar(
                    center: NSPoint(x: size * 0.70, y: size * 0.68),
                    outerRadius: size * 0.095,
                    innerRadius: size * 0.07
                )
                NSColor.black.setFill()
                star.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // One input and three round-ended outputs; the outer arms turn horizontal.
    // Shared vector geometry also drives the generated AppIcon.icns/Assets.car.
    private static func drawRoutingE(
        in rect: NSRect,
        color: NSColor,
        lineWidth: CGFloat,
        branchHeight: CGFloat
    ) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        let path = NSBezierPath()
        path.move(to: point(0.13, 0.50))
        path.line(to: point(0.86, 0.50))
        for direction: CGFloat in [-1, 1] {
            let terminalY = 0.50 + direction * branchHeight
            path.move(to: point(0.26, 0.50))
            path.curve(
                to: point(0.70, terminalY),
                controlPoint1: point(0.48, 0.50),
                controlPoint2: point(0.44, terminalY)
            )
            path.line(to: point(0.82, terminalY))
        }
        color.setStroke()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func fourPointStar(center: NSPoint, outerRadius: CGFloat, innerRadius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y + outerRadius))
        path.curve(
            to: NSPoint(x: center.x + outerRadius, y: center.y),
            controlPoint1: NSPoint(x: center.x, y: center.y + innerRadius),
            controlPoint2: NSPoint(x: center.x + innerRadius, y: center.y)
        )
        path.curve(
            to: NSPoint(x: center.x, y: center.y - outerRadius),
            controlPoint1: NSPoint(x: center.x + innerRadius, y: center.y),
            controlPoint2: NSPoint(x: center.x, y: center.y - innerRadius)
        )
        path.curve(
            to: NSPoint(x: center.x - outerRadius, y: center.y),
            controlPoint1: NSPoint(x: center.x, y: center.y - innerRadius),
            controlPoint2: NSPoint(x: center.x - innerRadius, y: center.y)
        )
        path.curve(
            to: NSPoint(x: center.x, y: center.y + outerRadius),
            controlPoint1: NSPoint(x: center.x - innerRadius, y: center.y),
            controlPoint2: NSPoint(x: center.x, y: center.y + innerRadius)
        )
        path.close()
        return path
    }
}
