import AppKit
import UniformTypeIdentifiers

// Builds Projector/Resources/DocumentIcon.icns: the logo on the system's own
// blank document page.
//
// The logo alone is black on transparent, so as a Finder icon it disappeared
// against a dark window. Finder shows one file icon in both appearances, so the
// answer is a light page behind the logo rather than a white variant. The
// system-generated document icon (CFBundleTypeIconSystemGenerated) would be the
// page plus the app icon for free, but on macOS 26 it rendered blank or as a
// "?" page - so the page is taken from the system and composited here instead.
//
// Usage: swift scripts/make-document-icon.swift <logo.png> <out.icns>

let logoURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let logo = NSImage(contentsOf: logoURL) else {
    fatalError("Cannot read logo at \(logoURL.path)")
}
// The blank page Finder draws for a plain file, at every size it provides.
let page = NSWorkspace.shared.icon(for: .data)

// Where the logo sits on the page, as fractions of the icon's side. The page
// body spans roughly the middle 60% of the canvas; the logo's own transparent
// margin keeps it clear of the folded corner.
let logoWidthFraction: CGFloat = 0.42
let logoCentreYFraction: CGFloat = 0.47

/// Points and scale for each slot `iconutil` expects in an iconset.
let slots: [(points: Int, scale: Int)] = [16, 32, 128, 256, 512].flatMap { [($0, 1), ($0, 2)] }

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("DocumentIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for slot in slots {
    let pixels = slot.points * slot.scale
    let side = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Cannot allocate \(pixels)px bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    page.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    let logoSide = side * logoWidthFraction
    logo.draw(in: NSRect(
        x: (side - logoSide) / 2,
        y: side * logoCentreYFraction - logoSide / 2,
        width: logoSide, height: logoSide
    ))
    NSGraphicsContext.restoreGraphicsState()

    let suffix = slot.scale == 1 ? "" : "@\(slot.scale)x"
    let name = "icon_\(slot.points)x\(slot.points)\(suffix).png"
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode \(name)")
    }
    try png.write(to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(outURL.path)")
