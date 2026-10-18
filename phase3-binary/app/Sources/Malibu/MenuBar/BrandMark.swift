import AppKit
import SwiftUI

// Malibu Construction logo symbol: a coral half-sun whose dome is a cut-out
// (negative space ringed by a coral band), seven tapered rays, and two
// horizontal side beams along the baseline, over two faint coral arches.
// `MalibuConstructionSunburstGeometry` holds the brand outline; the in-app
// tile, the Dock icon PNGs, the checked-in SVG (both written by
// scripts/generate-app-icon.sh) and the menu-bar glyph all derive from it.
//
// Brand palette (Malibu brand guidelines, primary and secondary colours):
//   Ocean Night  #143A45   (tile)
//   Ice White    #FAFBFF   (Dock icon tile)
//   Sunset Coral #F76B57   (sunburst)
//   Malibu Gold  #FFC629   (secondary accent, kept out of this glyph)

enum MalibuBrand {
    static let deepTeal   = Color(red: 0x14/255, green: 0x3A/255, blue: 0x45/255)
    static let cream      = Color(red: 0xFF/255, green: 0xFB/255, blue: 0xF2/255)
    static let coral      = Color(red: 0xF7/255, green: 0x6B/255, blue: 0x57/255)
    static let sunnyYellow = Color(red: 0xFF/255, green: 0xC6/255, blue: 0x29/255)

    static let deepTealNS = NSColor(srgbRed: 0x14/255, green: 0x3A/255, blue: 0x45/255, alpha: 1)
    static let creamNS    = NSColor(srgbRed: 0xFF/255, green: 0xFB/255, blue: 0xF2/255, alpha: 1)
    static let coralNS    = NSColor(srgbRed: 0xF7/255, green: 0x6B/255, blue: 0x57/255, alpha: 1)
    static let iceWhiteNS = NSColor(srgbRed: 0xFA/255, green: 0xFB/255, blue: 0xFF/255, alpha: 1)

    /// Asset identity for tests: v2 is the brand-kit outline (cut-out dome,
    /// seven rays, side beams); v1 was the nine-wedge approximation.
    static let constructionMarkIdentity = "malibu.construction-sunburst.v2"
}

/// Full-colour brand tile: Ocean Night rounded square, faint coral arches,
/// coral Construction mark, laid out as the brand kit's symbol tile.
struct MalibuBrandTile: View {
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let tile = CGRect(x: 0, y: 0, width: s, height: s)
            let layout = MalibuConstructionSunburstGeometry.Layout.symbolTile
            ZStack {
                RoundedRectangle(cornerRadius: s * layout.cornerRadius, style: .continuous)
                    .fill(MalibuBrand.deepTeal)
                Path(MalibuConstructionSunburstGeometry.outerArchPath(in: tile, layout: layout, yUp: false))
                    .fill(MalibuBrand.coral.opacity(MalibuConstructionSunburstGeometry.outerArchOpacity))
                Path(MalibuConstructionSunburstGeometry.innerArchPath(in: tile, layout: layout, yUp: false))
                    .fill(MalibuBrand.coral.opacity(MalibuConstructionSunburstGeometry.innerArchOpacity))
                Path(MalibuConstructionSunburstGeometry.markPath(in: tile, layout: layout, yUp: false))
                    .fill(MalibuBrand.coral)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Menu-bar glyph (#2029 P1-20, SPEC-025 §3.2): the Construction mark re-cut
/// for the status bar. The brand outline's rays are under 1 pt wide at this
/// size, so the glyph keeps the mark's layout (cut-out dome, band, seven rays
/// at the brand angles, two baseline side beams) and thickens every stroke
/// to at least 1.5 pt. Ink is about 14.7 pt tall in an 18 pt canvas.
enum MalibuMenuBarIcon {
    enum Badge: Equatable {
        /// Serving or idle: the plain template glyph.
        case none
        /// Paused: a hollow ring cut into the template, still template.
        case paused
        /// Needs attention: a red dot; the image is not a template so the
        /// dot keeps its colour, and the glyph is drawn in the label colour.
        case attention
    }

    private typealias Mark = MalibuConstructionSunburstGeometry

    static let canvasHeight: CGFloat = 18
    static let canvasWidth: CGFloat = 34
    /// Bottom edge of the dome, band and side beams.
    static let baselineY: CGFloat = 1.25
    /// Side-beam tips sit 0.9 pt inside the canvas edges.
    static let markScale: CGFloat = (canvasWidth / 2 - 0.9) / Mark.sideBeamTipX
    static var cutoutRadius: CGFloat { Mark.cutoutRadius * markScale }
    /// Outer radius of the band that rings the cut-out; rays grow from it.
    static var rayInnerRadius: CGFloat { Mark.bandRadius * markScale }
    static var rayTipRadii: [CGFloat] { Mark.rayTipRadii.map { $0 * markScale } }
    static var rayAnglesDegrees: [Double] { Mark.rayAnglesDegrees }
    static var sideBeamTipX: CGFloat { Mark.sideBeamTipX * markScale }
    static let rayBaseWidth: CGFloat = 2.6
    /// Narrowest stroke in the glyph: the ray tips and the side beams.
    static let rayStrokeWidth: CGFloat = 1.6
    static let sideBeamThickness: CGFloat = 1.6
    static let badgeDiameter: CGFloat = 6
    static let badgeRingWidth: CGFloat = 1.5

    static var size: NSSize { NSSize(width: canvasWidth, height: canvasHeight) }

    static func make(badge: Badge = .none) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let glyphColor: NSColor = badge == .attention ? .labelColor : .black
            drawGlyph(in: rect, color: glyphColor, clearBadge: badge != .none)
            switch badge {
            case .none:
                break
            case .paused:
                let ring = NSBezierPath(ovalIn: badgeRect(in: rect).insetBy(dx: badgeRingWidth / 2, dy: badgeRingWidth / 2))
                ring.lineWidth = badgeRingWidth
                NSColor.black.setStroke()
                ring.stroke()
            case .attention:
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: badgeRect(in: rect)).fill()
            }
            return true
        }
        image.isTemplate = badge != .attention
        image.accessibilityDescription = accessibilityLabel(for: badge)
        return image
    }

    /// Kept for callers that want the plain template glyph.
    static func makeTemplate() -> NSImage { make(badge: .none) }

    static func accessibilityLabel(for badge: Badge) -> String {
        switch badge {
        case .none: return "Malibu"
        case .paused: return "Malibu — paused"
        case .attention: return "Malibu — needs attention"
        }
    }

    static func badgeRect(in rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - badgeDiameter, y: rect.maxY - badgeDiameter,
               width: badgeDiameter, height: badgeDiameter)
    }

    /// The glyph outline in a y-up canvas whose origin is the bottom-left corner.
    static func glyphPath(in rect: CGRect) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.minY + baselineY)
        // Each piece is a separate path; unioning them one by one keeps
        // their winding directions from cancelling where they overlap.
        var pieces: [CGPath] = []
        // Band: upper half-disc; the cut-out is removed below.
        let band = CGMutablePath()
        band.addArc(center: center, radius: rayInnerRadius, startAngle: 0, endAngle: .pi, clockwise: false)
        band.closeSubpath()
        pieces.append(band)
        // Side beams: flat on the baseline, rounded at the outer tips.
        let beamWidth = sideBeamTipX
        for x in [center.x - beamWidth, center.x] {
            pieces.append(CGPath(roundedRect: CGRect(x: x, y: center.y, width: beamWidth, height: sideBeamThickness),
                                 cornerWidth: sideBeamThickness / 2, cornerHeight: sideBeamThickness / 2,
                                 transform: nil))
        }
        // Rays: tapered from the band to a round tip at the brand tip radius.
        let baseRadius = rayInnerRadius * 0.8
        for (degrees, tipRadius) in zip(rayAnglesDegrees, rayTipRadii) {
            let a = degrees * .pi / 180
            let dir = CGPoint(x: CGFloat(cos(a)), y: CGFloat(sin(a)))
            let normal = CGPoint(x: -dir.y, y: dir.x)
            let tipCenterRadius = tipRadius - rayStrokeWidth / 2
            func at(_ r: CGFloat, _ offset: CGFloat) -> CGPoint {
                CGPoint(x: center.x + dir.x * r + normal.x * offset, y: center.y + dir.y * r + normal.y * offset)
            }
            let ray = CGMutablePath()
            ray.addLines(between: [at(baseRadius, rayBaseWidth / 2), at(tipCenterRadius, rayStrokeWidth / 2),
                                   at(tipCenterRadius, -rayStrokeWidth / 2), at(baseRadius, -rayBaseWidth / 2)])
            ray.closeSubpath()
            pieces.append(ray)
            let tip = at(tipCenterRadius, 0)
            pieces.append(CGPath(ellipseIn: CGRect(x: tip.x - rayStrokeWidth / 2, y: tip.y - rayStrokeWidth / 2,
                                                   width: rayStrokeWidth, height: rayStrokeWidth),
                                 transform: nil))
        }
        let ink = pieces.dropFirst().reduce(pieces[0]) { $0.union($1) }
        let cutout = CGPath(ellipseIn: CGRect(x: center.x - cutoutRadius, y: center.y - cutoutRadius,
                                              width: cutoutRadius * 2, height: cutoutRadius * 2),
                            transform: nil)
        return ink.subtracting(cutout)
    }

    static func drawGlyph(in rect: CGRect, color: NSColor, clearBadge: Bool) {
        NSGraphicsContext.saveGraphicsState()
        if clearBadge {
            // Leave a gap around the badge so it reads as separate.
            let clip = NSBezierPath(rect: rect)
            clip.append(NSBezierPath(ovalIn: badgeRect(in: rect).insetBy(dx: -1.5, dy: -1.5)))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        color.setFill()
        NSBezierPath(cgPath: glyphPath(in: rect)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Shared Construction sunburst model (brand-kit outline)

/// The Construction symbol from the Malibu brand kit ("2.2 - CONSTRUCTION
/// LOGO Symbols"), in its own points with the origin at the baseline centre
/// of the dome and y pointing up. The mark is 290.8 pt wide and 133.0 pt tall.
enum MalibuConstructionSunburstGeometry {
    enum Element {
        case move(CGFloat, CGFloat)
        case line(CGFloat, CGFloat)
        case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case close
    }

    /// Coral outline exactly as drawn in the brand kit: band, seven rays and
    /// both side beams in one contour, with the dome left open.
    static let outline: [Element] = [
        .move(-20.836, 27.305),
        .curve(-7.902, 33.957, 7.309, 33.898, 20.094, 27.684),
        .curve(30.703, 22.223, 36.926, 12.145, 36.746, 0.000),
        .line(142.754, 0.016),
        .curve(144.586, 0.652, 145.527, 3.672, 145.375, 5.121),
        .curve(145.242, 6.387, 143.938, 9.199, 142.297, 9.270),
        .line(82.684, 11.758),
        .curve(80.742, 11.840, 78.836, 13.766, 78.551, 15.332),
        .curve(78.211, 17.199, 79.043, 19.121, 80.758, 20.375),
        .line(125.121, 52.730),
        .curve(127.406, 54.398, 128.809, 56.246, 127.641, 58.941),
        .curve(126.695, 61.121, 124.008, 62.648, 121.398, 61.492),
        .line(70.695, 39.047),
        .curve(68.660, 38.145, 66.262, 38.148, 64.844, 39.309),
        .curve(63.801, 40.164, 62.582, 43.355, 63.500, 44.727),
        .line(94.969, 91.559),
        .curve(96.500, 93.840, 96.949, 96.145, 95.094, 98.266),
        .curve(93.703, 99.855, 90.539, 100.512, 88.621, 98.664),
        .line(47.340, 58.895),
        .curve(45.938, 57.543, 43.242, 57.832, 42.062, 58.590),
        .curve(40.312, 59.723, 39.449, 61.891, 39.984, 64.043),
        .line(53.102, 117.184),
        .curve(53.922, 120.504, 53.535, 123.145, 50.082, 124.277),
        .curve(47.023, 125.285, 45.289, 123.121, 43.828, 120.129),
        .line(20.254, 71.891),
        .curve(19.145, 69.617, 17.359, 68.137, 15.035, 68.477),
        .curve(13.258, 68.742, 11.297, 70.512, 11.070, 72.629),
        .line(5.051, 128.645),
        .curve(4.750, 131.441, 2.477, 133.164, 0.016, 133.027),
        .curve(-2.133, 132.910, -4.086, 131.160, -4.352, 128.668),
        .line(-10.516, 71.449),
        .curve(-10.680, 69.918, -13.727, 68.340, -15.047, 68.375),
        .curve(-16.238, 68.410, -18.441, 69.516, -19.125, 70.910),
        .line(-44.414, 122.535),
        .curve(-45.430, 124.613, -48.820, 124.762, -50.352, 123.883),
        .curve(-52.488, 122.652, -53.230, 120.422, -52.609, 117.910),
        .line(-44.105, 83.512),
        .line(-39.191, 63.270),
        .curve(-38.691, 61.207, -40.441, 58.598, -42.344, 58.066),
        .curve(-43.914, 57.625, -45.949, 58.227, -47.426, 59.648),
        .line(-87.227, 98.000),
        .curve(-89.316, 100.012, -92.023, 100.375, -94.074, 98.563),
        .curve(-96.129, 96.750, -95.902, 94.023, -94.293, 91.625),
        .line(-63.727, 46.117),
        .curve(-62.383, 44.125, -62.238, 42.008, -63.254, 40.469),
        .curve(-64.496, 38.574, -66.930, 37.707, -68.992, 38.621),
        .line(-98.621, 51.699),
        .line(-119.746, 61.117),
        .curve(-122.754, 62.457, -125.715, 61.902, -127.008, 58.941),
        .curve(-128.301, 55.980, -126.496, 54.211, -124.047, 52.422),
        .line(-79.703, 20.098),
        .curve(-78.020, 18.871, -77.496, 16.535, -78.051, 14.770),
        .curve(-78.445, 13.504, -80.324, 11.816, -82.062, 11.742),
        .line(-143.133, 9.121),
        .curve(-146.176, 8.625, -146.078, 1.805, -143.223, 0.074),
        .line(-36.754, 0.039),
        .curve(-36.918, 11.738, -31.324, 21.574, -20.836, 27.312),
        .close,
    ]

    /// The brand kit widens the dome opening with a background-coloured disc;
    /// subtracting it reproduces the visible cut-out.
    static let cutoutCenter = CGPoint(x: 0.949, y: -5.703)
    static let cutoutRadius: CGFloat = 39.910
    static let innerArchCenter = CGPoint(x: 0, y: 2.848)
    static let innerArchRadius: CGFloat = 111.180
    static let innerArchOpacity: Double = 0.2
    static let outerArchCenter = CGPoint(x: 0.949, y: 0)
    static let outerArchRadius: CGFloat = 163.445
    static let outerArchOpacity: Double = 0.1

    /// Measured from `outline`: ray tip directions and distances from the
    /// origin, the closest valley between rays, and the side-beam tips.
    static let rayAnglesDegrees: [Double] = [24.79, 46.07, 67.83, 89.83, 111.88, 133.83, 155.11]
    static let rayTipRadii: [CGFloat] = [140.59, 136.76, 134.01, 133.03, 133.75, 136.25, 140.02]
    static let bandRadius: CGFloat = 69.95
    static let sideBeamTipX: CGFloat = 145.39
    static var rayCount: Int { rayAnglesDegrees.count }
    /// The side beams run along the baseline, left and right.
    static let sideBeamAnglesDegrees: [Double] = [0, 180]

    /// Where the mark sits in a square tile, in mark points.
    struct Layout {
        /// Tile side length in mark points.
        let tileSide: CGFloat
        /// Baseline position as a fraction of the tile side, from the top.
        let baselineFromTop: CGFloat
        /// Corner radius as a fraction of the tile side.
        let cornerRadius: CGFloat

        /// Brand kit symbol tile: 363 pt tile, baseline 247.07 pt from the top, 66.48 pt corners.
        static let symbolTile = Layout(tileSide: 363, baselineFromTop: 247.066 / 363, cornerRadius: 66.48 / 363)
        /// Brand kit macOS icon ("5.2 - MACOS ICON"), measured: the mark is
        /// 72.2% of the tile width and the baseline sits 68.5% down the tile.
        static let appIcon = Layout(tileSide: 402.7, baselineFromTop: 0.685, cornerRadius: 185.4 / 824)
    }

    private static let unitOutline: CGPath = {
        let path = CGMutablePath()
        for element in outline {
            switch element {
            case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
            case let .line(x, y): path.addLine(to: CGPoint(x: x, y: y))
            case let .curve(x1, y1, x2, y2, x, y):
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }()

    private static func disc(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
               transform: nil)
    }

    private static let aboveBaseline = CGPath(rect: CGRect(x: -400, y: 0, width: 800, height: 400), transform: nil)

    static let unitMark: CGPath = unitOutline.subtracting(disc(cutoutCenter, cutoutRadius))
    static let unitInnerArch: CGPath = disc(innerArchCenter, innerArchRadius).intersection(aboveBaseline)
    static let unitOuterArch: CGPath = disc(outerArchCenter, outerArchRadius).intersection(aboveBaseline)

    /// Maps mark points into `tile`. With `yUp` false the result suits
    /// SwiftUI and flipped views.
    static func transform(in tile: CGRect, layout: Layout, yUp: Bool) -> CGAffineTransform {
        let side = min(tile.width, tile.height)
        let scale = side / layout.tileSide
        let top = yUp ? tile.midY + side / 2 : tile.midY - side / 2
        let baseline = yUp ? top - layout.baselineFromTop * side : top + layout.baselineFromTop * side
        return CGAffineTransform(a: scale, b: 0, c: 0, d: yUp ? scale : -scale, tx: tile.midX, ty: baseline)
    }

    private static func place(_ path: CGPath, _ tile: CGRect, _ layout: Layout, _ yUp: Bool) -> CGPath {
        var t = transform(in: tile, layout: layout, yUp: yUp)
        return path.copy(using: &t) ?? path
    }

    static func markPath(in tile: CGRect, layout: Layout = .symbolTile, yUp: Bool) -> CGPath {
        place(unitMark, tile, layout, yUp)
    }

    static func innerArchPath(in tile: CGRect, layout: Layout = .symbolTile, yUp: Bool) -> CGPath {
        place(unitInnerArch, tile, layout, yUp)
    }

    static func outerArchPath(in tile: CGRect, layout: Layout = .symbolTile, yUp: Bool) -> CGPath {
        place(unitOuterArch, tile, layout, yUp)
    }

    static func fill(in rect: CGRect, color: NSColor, yUp: Bool) {
        color.setFill()
        path(in: rect, yUp: yUp).fill()
    }

    /// The mark as it sits in the symbol tile `rect`.
    static func path(in rect: CGRect, yUp: Bool) -> NSBezierPath {
        NSBezierPath(cgPath: markPath(in: rect, yUp: yUp))
    }

    static func swiftUIPath(in rect: CGRect) -> Path {
        Path(markPath(in: rect, yUp: false))
    }

    // MARK: App icon (Dock), written by scripts/generate-app-icon.sh

    /// macOS icon grid: an 824 px tile centred on a 1024 px canvas.
    static let appIconTileFraction: CGFloat = 824.0 / 1024.0

    static func appIconTileRect(canvas side: CGFloat) -> CGRect {
        let tile = side * appIconTileFraction
        return CGRect(x: (side - tile) / 2, y: (side - tile) / 2, width: tile, height: tile)
    }

    static func appIconTilePath(canvas side: CGFloat) -> CGPath {
        let tile = appIconTileRect(canvas: side)
        return RoundedRectangle(cornerRadius: tile.width * Layout.appIcon.cornerRadius, style: .continuous)
            .path(in: tile).cgPath
    }

    /// Draws the Dock icon into a y-up context covering `side` × `side` pixels.
    static func drawAppIcon(in context: CGContext, side: CGFloat) {
        let tile = appIconTileRect(canvas: side)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -side * 0.008), blur: side * 0.02,
                          color: NSColor.black.withAlphaComponent(0.3).cgColor)
        context.addPath(appIconTilePath(canvas: side))
        context.setFillColor(MalibuBrand.iceWhiteNS.cgColor)
        context.fillPath()
        context.restoreGState()
        let coral = MalibuBrand.coralNS
        for (path, alpha) in [(outerArchPath(in: tile, layout: .appIcon, yUp: true), outerArchOpacity),
                              (innerArchPath(in: tile, layout: .appIcon, yUp: true), innerArchOpacity),
                              (markPath(in: tile, layout: .appIcon, yUp: true), 1.0)] {
            context.addPath(path)
            context.setFillColor(coral.withAlphaComponent(alpha).cgColor)
            context.fillPath()
        }
    }

    /// SVG path data for a y-down path, two decimals.
    static func svgPathData(_ path: CGPath) -> String {
        var parts: [String] = []
        func f(_ p: CGPoint) -> String { String(format: "%.2f %.2f", locale: Locale(identifier: "en_US_POSIX"), p.x, p.y) }
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint: parts.append("M\(f(e.points[0]))")
            case .addLineToPoint: parts.append("L\(f(e.points[0]))")
            case .addQuadCurveToPoint: parts.append("Q\(f(e.points[0])) \(f(e.points[1]))")
            case .addCurveToPoint: parts.append("C\(f(e.points[0])) \(f(e.points[1])) \(f(e.points[2]))")
            case .closeSubpath: parts.append("Z")
            @unknown default: break
            }
        }
        return parts.joined(separator: " ")
    }

    /// The Dock icon as an SVG document on a 1024 × 1024 canvas.
    static func appIconSVG() -> String {
        let side: CGFloat = 1024
        let tile = appIconTileRect(canvas: side)
        let svgTile = RoundedRectangle(cornerRadius: tile.width * Layout.appIcon.cornerRadius, style: .continuous)
            .path(in: tile).cgPath
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
          <!-- Generated by phase3-binary/app/scripts/generate-app-icon.sh from MalibuConstructionSunburstGeometry. Do not edit. -->
          <defs><filter id="shadow" x="-10%" y="-10%" width="120%" height="120%"><feDropShadow dx="0" dy="8.19" stdDeviation="10.24" flood-color="#000" flood-opacity="0.3"/></filter></defs>
          <path filter="url(#shadow)" fill="#FAFBFF" d="\(svgPathData(svgTile))"/>
          <path fill="#F76B57" fill-opacity="\(outerArchOpacity)" d="\(svgPathData(outerArchPath(in: tile, layout: .appIcon, yUp: false)))"/>
          <path fill="#F76B57" fill-opacity="\(innerArchOpacity)" d="\(svgPathData(innerArchPath(in: tile, layout: .appIcon, yUp: false)))"/>
          <path fill="#F76B57" d="\(svgPathData(markPath(in: tile, layout: .appIcon, yUp: false)))"/>
        </svg>

        """
    }
}
