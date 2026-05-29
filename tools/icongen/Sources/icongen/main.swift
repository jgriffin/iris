import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
func renderPNG<V: View>(_ view: V, pixelSize: CGFloat) -> NSImage? {
    let renderer = ImageRenderer(content: view.frame(width: pixelSize, height: pixelSize))
    renderer.scale = 1.0 // we render at native point==pixel; size IS the pixel count
    return renderer.nsImage
}

@MainActor
func writePNG(_ image: NSImage, to url: URL) -> Bool {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return false }
    do { try data.write(to: url); return true } catch { return false }
}

// One row of the contact sheet: a label, the hero (scaled-to-fit) and the
// actual-pixel small ramp so 16px legibility is judgeable.
struct VariantRow: View {
    let variant: IrisVariant
    let heroSize: CGFloat
    let ramp: [CGFloat]
    let textColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(variant.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textColor)
                Text("hero scaled-to-fit · ramp at actual pixels")
                    .font(.system(size: 10))
                    .foregroundColor(textColor.opacity(0.6))
            }
            .frame(width: 200, alignment: .leading)

            // hero (a high-res render scaled down to heroSize for display)
            IrisIcon(variant: variant, size: heroSize)

            // actual-pixel ramp
            HStack(alignment: .bottom, spacing: 18) {
                ForEach(ramp, id: \.self) { s in
                    VStack(spacing: 4) {
                        IrisIcon(variant: variant, size: s)
                            .frame(width: s, height: s)
                        Text("\(Int(s))px")
                            .font(.system(size: 9))
                            .foregroundColor(textColor.opacity(0.7))
                    }
                }
            }
        }
    }
}

struct ContactSheet: View {
    let dark: Bool
    let ramp: [CGFloat] = [128, 64, 32, 16]
    let heroSize: CGFloat = 160

    var pageBG: Color {
        dark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color(red: 0.96, green: 0.96, blue: 0.97)
    }
    var textColor: Color { dark ? .white : .black }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Iris app-icon directions — \(dark ? "dark" : "light") page")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(textColor)
            ForEach(IrisVariant.allCases, id: \.self) { v in
                VariantRow(variant: v, heroSize: heroSize, ramp: ramp, textColor: textColor)
            }
        }
        .padding(36)
        .frame(width: 820, alignment: .leading)
        .background(pageBG)
    }
}

// Combine light + dark sheets side by side into one PNG.
struct CombinedSheet: View {
    var body: some View {
        HStack(spacing: 0) {
            ContactSheet(dark: false)
            ContactSheet(dark: true)
        }
    }
}

@MainActor
func run() {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                   ?? FileManager.default.currentDirectoryPath)
    let previewDir = base.appendingPathComponent("preview")
    try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)

    // 1) individual full-res renders at real app-icon sizes
    let sizes: [CGFloat] = [1024, 512, 256, 128, 64, 32, 16]
    let names: [IrisVariant: String] = [.eye: "v1", .aperture: "v2", .minimal: "v3"]
    for v in IrisVariant.allCases {
        for s in sizes {
            if let img = renderPNG(IrisIcon(variant: v, size: s), pixelSize: s) {
                let url = previewDir.appendingPathComponent("\(names[v]!)-\(Int(s)).png")
                _ = writePNG(img, to: url)
            }
        }
    }

    // 2) combined light+dark contact sheet. Render at 2x for crispness.
    let sheet = CombinedSheet()
    let renderer = ImageRenderer(content: sheet)
    renderer.scale = 2.0
    if let img = renderer.nsImage {
        let url = previewDir.appendingPathComponent("icon-contactsheet.png")
        if writePNG(img, to: url) {
            FileHandle.standardOutput.write("wrote \(url.path)\n".data(using: .utf8)!)
        }
    }
    // 3) the real AppIcon.appiconset for the approved variant (V2 aperture).
    emitAppIconSet(variant: .aperture, into: previewDir)

    FileHandle.standardOutput.write("done -> \(previewDir.path)\n".data(using: .utf8)!)
}

// MARK: - AppIcon.appiconset emission

/// Emit a single combined `AppIcon.appiconset` carrying the macOS idiom (full
/// 16–512 @1x/2x ramp) plus the iOS `universal` single-1024 idiom. Each PNG is
/// rendered at its exact pixel dimension (points × scale). Filenames are unique
/// per pixel size and reused across entries where the pixel dims coincide.
@MainActor
func emitAppIconSet(variant: IrisVariant, into previewDir: URL) {
    let fm = FileManager.default
    let setDir = previewDir.appendingPathComponent("AppIcon.appiconset")
    try? fm.removeItem(at: setDir)
    try? fm.createDirectory(at: setDir, withIntermediateDirectories: true)

    struct Entry { let idiom: String; let size: String; let scale: String?; let platform: String?; let px: Int }
    // macOS ramp: point size + scale -> pixel size.
    let macPoints: [(pt: Int, scales: [Int])] = [
        (16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])
    ]
    var entries: [Entry] = []
    for (pt, scales) in macPoints {
        for sc in scales {
            entries.append(Entry(idiom: "mac", size: "\(pt)x\(pt)", scale: "\(sc)x", platform: nil, px: pt * sc))
        }
    }
    // iOS modern single-icon: universal idiom tagged `platform: ios`,
    // 1024x1024, no scale token. The `platform` tag is what lets a single
    // combined set carry both the mac ramp and the iOS single icon; without
    // it the bare `universal` entry reads as macOS-legacy and the iOS
    // actool reports "no applicable content".
    entries.append(Entry(idiom: "universal", size: "1024x1024", scale: nil, platform: "ios", px: 1024))

    // Render each distinct pixel size once; share the file across entries.
    let distinctPx = Set(entries.map { $0.px }).sorted()
    var fileForPx: [Int: String] = [:]
    for px in distinctPx {
        let name = "AppIcon-\(px).png"
        fileForPx[px] = name
        if let img = renderPNG(IrisIcon(variant: variant, size: CGFloat(px)), pixelSize: CGFloat(px)) {
            _ = writePNG(img, to: setDir.appendingPathComponent(name))
        }
    }

    // Build Contents.json.
    var images: [String] = []
    for e in entries {
        // Key order: filename, idiom, platform?, scale?, size (xcode-style).
        var fields = ["\"filename\" : \"\(fileForPx[e.px]!)\"",
                      "\"idiom\" : \"\(e.idiom)\""]
        if let platform = e.platform { fields.append("\"platform\" : \"\(platform)\"") }
        if let scale = e.scale { fields.append("\"scale\" : \"\(scale)\"") }
        fields.append("\"size\" : \"\(e.size)\"")
        images.append("    {\n      " + fields.joined(separator: ",\n      ") + "\n    }")
    }
    let json = """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try? json.write(to: setDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    FileHandle.standardOutput.write("wrote \(setDir.path)\n".data(using: .utf8)!)
}

MainActor.assumeIsolated { run() }
