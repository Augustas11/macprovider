import AppKit
import SwiftUI

// Malibu Construction logo symbol — coral sunburst (semicircle + 9 rays)
// inside the deep-teal arch/tile. Authoritative normalized geometry lives in
// `MalibuConstructionSunburstGeometry`; AppKit, SwiftUI, and the checked-in
// SVG all consume those same constants (SVG is a static export of this model).
//
// Brand palette (matches malibu.tech / Construction logo):
//   deep teal    #143A45   (background / tile)
//   cream        #FFFBF2   (contrast copy)
//   coral        #FF6E5B   (sunburst accent)
//   sunny yellow #FFC629   (secondary accent, kept out of this glyph)

enum MalibuBrand {
    static let deepTeal   = Color(red: 0x14/255, green: 0x3A/255, blue: 0x45/255)
    static let cream      = Color(red: 0xFF/255, green: 0xFB/255, blue: 0xF2/255)
    static let coral      = Color(red: 0xFF/255, green: 0x6E/255, blue: 0x5B/255)
    static let sunnyYellow = Color(red: 0xFF/255, green: 0xC6/255, blue: 0x29/255)

    static let deepTealNS = NSColor(srgbRed: 0x14/255, green: 0x3A/255, blue: 0x45/255, alpha: 1)
    static let creamNS    = NSColor(srgbRed: 0xFF/255, green: 0xFB/255, blue: 0xF2/255, alpha: 1)
    static let coralNS    = NSColor(srgbRed: 0xFF/255, green: 0x6E/255, blue: 0x5B/255, alpha: 1)

    /// Asset identity for tests — Construction sunburst, not the legacy horizon mark.
    static let constructionMarkIdentity = "malibu.construction-sunburst.v1"
}

/// Full-color brand tile — deep-teal rounded square with coral Construction sunburst.
struct MalibuBrandTile: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                    .fill(MalibuBrand.deepTeal)
                MalibuConstructionSunburstShape()
                    .fill(MalibuBrand.coral)
                    .padding(s * 0.14)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Monochrome Construction sunburst silhouette for the menu bar.
enum MalibuMenuBarIcon {
    static let defaultPointSize: CGFloat = 18

    static func makeTemplate(pointSize: CGFloat = defaultPointSize) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            MalibuConstructionSunburstGeometry.fill(in: rect, color: .black, yUp: true)
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Shared Construction sunburst model (64×64 art board)

enum MalibuConstructionSunburstGeometry {
    static let artBoard: CGFloat = 64
    static let rayCount = 9
    static let centerYFromBottom: CGFloat = 26
    static let domeRadius: CGFloat = 12.5
    static let innerRadius: CGFloat = 13.5
    static let outerRadius: CGFloat = 28
    static let firstRayDegrees: Double = 12
    static let lastRayDegrees: Double = 168
    static let rayHalfWidthDegrees: Double = 7.2

    static var rayAnglesDegrees: [Double] {
        let step = (lastRayDegrees - firstRayDegrees) / Double(rayCount - 1)
        return (0..<rayCount).map { firstRayDegrees + step * Double($0) }
    }

    static func fill(in rect: CGRect, color: NSColor, yUp: Bool) {
        color.setFill()
        path(in: rect, yUp: yUp).fill()
    }

    static func path(in rect: CGRect, yUp: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let scale = min(rect.width, rect.height) / artBoard
        let center = CGPoint(
            x: rect.midX,
            y: yUp
                ? rect.minY + centerYFromBottom * scale
                : rect.maxY - centerYFromBottom * scale
        )
        let dome = domeRadius * scale
        let inner = innerRadius * scale
        let outer = outerRadius * scale

        if yUp {
            path.appendArc(withCenter: center, radius: dome, startAngle: 0, endAngle: 180, clockwise: false)
        } else {
            path.appendArc(withCenter: center, radius: dome, startAngle: 180, endAngle: 0, clockwise: false)
        }
        path.close()

        for angle in rayAnglesDegrees {
            let tip = point(center: center, radius: outer, degrees: angle, yUp: yUp)
            let left = point(center: center, radius: inner, degrees: angle + rayHalfWidthDegrees, yUp: yUp)
            let right = point(center: center, radius: inner, degrees: angle - rayHalfWidthDegrees, yUp: yUp)
            let ray = NSBezierPath()
            ray.move(to: left)
            ray.line(to: tip)
            ray.line(to: right)
            ray.close()
            path.append(ray)
        }
        return path
    }

    static func swiftUIPath(in rect: CGRect) -> Path {
        // Bridge through the shared AppKit path so SwiftUI cannot drift.
        Path(path(in: rect, yUp: false).cgPath)
    }

    private static func point(center: CGPoint, radius: CGFloat, degrees: Double, yUp: Bool) -> CGPoint {
        let radians = degrees * .pi / 180
        let dy = CGFloat(sin(radians)) * radius
        return CGPoint(
            x: center.x + CGFloat(cos(radians)) * radius,
            y: yUp ? center.y + dy : center.y - dy
        )
    }
}

private struct MalibuConstructionSunburstShape: Shape {
    func path(in rect: CGRect) -> Path {
        MalibuConstructionSunburstGeometry.swiftUIPath(in: rect)
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            let type = element(at: index, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        return path
    }
}
