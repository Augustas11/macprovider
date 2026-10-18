// Writes the Malibu.app AppIcon PNGs and the exported SVG from
// MalibuConstructionSunburstGeometry. Built and run by generate-app-icon.sh.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: app-icon <appiconset-dir> <svg-path>\n".data(using: .utf8)!)
    exit(2)
}
let iconSet = URL(fileURLWithPath: arguments[1])
let svgURL = URL(fileURLWithPath: arguments[2])

struct ContentsImage: Decodable { let size: String; let scale: String; let filename: String }
struct Contents: Decodable { let images: [ContentsImage] }
let contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: iconSet.appendingPathComponent("Contents.json")))

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
for image in contents.images {
    let points = Double(image.size.split(separator: "x")[0])!
    let scale = Double(image.scale.dropLast())!
    let pixels = Int(points * scale)
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("cannot create \(pixels) px context")
    }
    MalibuConstructionSunburstGeometry.drawAppIcon(in: context, side: CGFloat(pixels))
    let url = iconSet.appendingPathComponent(image.filename) as CFURL
    let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(image.filename)") }
    print("\(image.filename) \(pixels)x\(pixels)")
}
try MalibuConstructionSunburstGeometry.appIconSVG().write(to: svgURL, atomically: true, encoding: .utf8)
print("wrote \(svgURL.lastPathComponent)")
