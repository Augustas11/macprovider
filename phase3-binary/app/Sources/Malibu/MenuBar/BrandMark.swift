import AppKit
import SwiftUI

// Malibu brand mark — the horizon-with-half-sun glyph from favicon.svg.
// Source of truth for the shape lives at Resources/Brand/malibu-icon.svg;
// this Swift version is drawn in code so it renders at any size, adapts to
// dark mode automatically in template form, and stays crisp on Retina.
//
// Brand palette (matches malibu.tech):
//   deep teal    #143A45   (background / tile)
//   cream        #FFFBF2   (horizon line, contrast copy)
//   coral        #FF6E5B   (half-sun accent)
//   sunny yellow #FFC629   (secondary accent, kept out of this glyph)

enum MalibuBrand {
    static let deepTeal   = Color(red: 0x14/255, green: 0x3A/255, blue: 0x45/255)
    static let cream      = Color(red: 0xFF/255, green: 0xFB/255, blue: 0xF2/255)
    static let coral      = Color(red: 0xFF/255, green: 0x6E/255, blue: 0x5B/255)
    static let sunnyYellow = Color(red: 0xFF/255, green: 0xC6/255, blue: 0x29/255)

    static let deepTealNS = NSColor(srgbRed: 0x14/255, green: 0x3A/255, blue: 0x45/255, alpha: 1)
    static let creamNS    = NSColor(srgbRed: 0xFF/255, green: 0xFB/255, blue: 0xF2/255, alpha: 1)
    static let coralNS    = NSColor(srgbRed: 0xFF/255, green: 0x6E/255, blue: 0x5B/255, alpha: 1)
}

/// Full-color brand tile — deep-teal rounded square with cream horizon and coral half-sun.
/// Use in onboarding headers and the dashboard "brand" corner. Draws to fit any size.
struct MalibuBrandTile: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                    .fill(MalibuBrand.deepTeal)
                MalibuHorizonShape()
                    .stroke(MalibuBrand.cream, style: StrokeStyle(lineWidth: s * 0.053, lineCap: .round))
                MalibuSunShape()
                    .fill(MalibuBrand.coral)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Monochrome silhouette — the horizon + half-sun outline only, for the
/// menu bar. Rendered as an NSImage marked `isTemplate = true` so macOS
/// tints it automatically for light/dark mode and menu bar state.
enum MalibuMenuBarIcon {
    static func makeTemplate(pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            let sunR = rect.width * (13.0 / 64.0)
            // AppKit origin is bottom-left; SVG y=42 is 22/64 up from the bottom.
            // Center the sun+horizon band vertically, then nudge up slightly for menu-bar optics.
            let horizonY = rect.midY - sunR / 2 + rect.height * 0.04
            let x1 = rect.minX + rect.width * (10.0 / 64.0)
            let x2 = rect.minX + rect.width * (54.0 / 64.0)
            let path = NSBezierPath()

            path.move(to: NSPoint(x: x1, y: horizonY))
            path.line(to: NSPoint(x: x2, y: horizonY))
            path.lineWidth = rect.height * (3.4 / 64.0)
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()

            let center = NSPoint(x: rect.midX, y: horizonY)
            let sun = NSBezierPath()
            sun.appendArc(withCenter: center, radius: sunR, startAngle: 0, endAngle: 180)
            sun.close()
            NSColor.black.setFill()
            sun.fill()

            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Shapes (SwiftUI Paths, normalised to a 64×64 art board matching favicon.svg)

private struct MalibuHorizonShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Original SVG: line from (10,42) to (54,42) on 64×64
        let x1 = rect.minX + rect.width  * (10.0/64.0)
        let x2 = rect.minX + rect.width  * (54.0/64.0)
        let y  = rect.minY + rect.height * (42.0/64.0)
        var p = Path()
        p.move(to: CGPoint(x: x1, y: y))
        p.addLine(to: CGPoint(x: x2, y: y))
        return p
    }
}

private struct MalibuSunShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Original SVG: path "M19 42 a13 13 0 0 1 26 0 Z" on 64×64
        let center = CGPoint(
            x: rect.minX + rect.width  * (32.0/64.0),
            y: rect.minY + rect.height * (42.0/64.0)
        )
        let radius = rect.width * (13.0/64.0)
        var p = Path()
        p.move(to: CGPoint(x: center.x - radius, y: center.y))
        p.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(360),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
