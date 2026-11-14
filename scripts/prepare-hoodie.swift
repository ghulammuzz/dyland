import AppKit

// Preserve original artwork; fill only the connected eye pixels for blink frames.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Resources/Hoodie.png")
guard let data = try? Data(contentsOf: source), let bitmap = NSBitmapImageRep(data: data) else {
    fatalError("Missing Resources/Hoodie.png")
}
let width = bitmap.pixelsWide
precondition(width == 1254 && bitmap.pixelsHigh == 1254)
// Flood only the background connected to the upper corners, never similar-colored hair.
var background = Set<Int>()
var checked = Set<Int>()
var pending = [0, width - 1]
while let pixel = pending.popLast() {
    guard pixel >= 0, pixel < width * width, checked.insert(pixel).inserted else { continue }
    let x = pixel % width, y = pixel / width
    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          max(c.redComponent, c.greenComponent, c.blueComponent) < 0.19,
          min(c.redComponent, c.greenComponent, c.blueComponent) > 0.10 else { continue }
    background.insert(pixel)
    if x > 0 { pending.append(pixel - 1) }
    if x < width - 1 { pending.append(pixel + 1) }
    if y > 0 { pending.append(pixel - width) }
    if y < width - 1 { pending.append(pixel + width) }
}
precondition(background.count > 100_000 && background.count < 800_000, "Unexpected background area: \(background.count)")
precondition(!background.contains(592 * width + 259), "Background removal must preserve eyes")
precondition(!background.contains(800 * width + 50), "Background removal must preserve hair")

func exportCutout(_ name: String) throws {
    let cropWidth = 1000, cropHeight = 1140
    let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cropWidth, pixelsHigh: cropHeight,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Trim the torso with a shallow shoulder contour, not a circular avatar mask.
    let silhouette = CGMutablePath()
    silhouette.move(to: .zero)
    silhouette.addLine(to: CGPoint(x: 1000, y: 0))
    silhouette.addLine(to: CGPoint(x: 1000, y: 1000))
    silhouette.addCurve(to: CGPoint(x: 650, y: 1140), control1: CGPoint(x: 1000, y: 1110), control2: CGPoint(x: 850, y: 1140))
    silhouette.addLine(to: CGPoint(x: 300, y: 1140))
    silhouette.addCurve(to: CGPoint(x: 0, y: 1030), control1: CGPoint(x: 150, y: 1140), control2: CGPoint(x: 0, y: 1120))
    silhouette.closeSubpath()
    for y in 0..<cropHeight {
        for x in 0..<cropWidth {
            let visible = !background.contains(y * width + x) && silhouette.contains(CGPoint(x: x, y: y))
            let offset = y * output.bytesPerRow + x * 4
            let bytes = output.bitmapData!
            if visible {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                for (channel, value) in [color.redComponent, color.greenComponent, color.blueComponent].enumerated() {
                    bytes[offset + channel] = UInt8(max(0, min(255, (value * 255).rounded())))
                }
                bytes[offset + 3] = 255
            } else {
                for channel in 0..<4 { bytes[offset + channel] = 0 }
            }
        }
    }
    precondition(output.colorAt(x: 990, y: 500)!.alphaComponent == 0)
    precondition(output.colorAt(x: 400, y: 700)!.alphaComponent == 1)
    guard let png = output.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try png.write(to: root.appendingPathComponent("Resources/\(name).png"))
}
try exportCutout("Hoodie-Cutout")

for seed in [(259, 592), (555, 708)] {
    var queue = [seed]
    var visited = Set<Int>()
    var mask = Set<Int>()
    while let (x, y) = queue.popLast() {
        guard x >= 0, x < width, y >= 0, y < bitmap.pixelsHigh,
              visited.insert(y * width + x).inserted,
              let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
              max(c.redComponent, c.greenComponent, c.blueComponent) < 0.5 else { continue }
        mask.insert(y * width + x)
        queue += [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
    }
    precondition(mask.count > 6000 && mask.count < 12000, "Mask must contain only one eye")
    var expanded = mask
    for pixel in mask {
        for dy in -2...2 {
            for dx in -2...2 { expanded.insert(pixel + dy * width + dx) }
        }
    }
    for pixel in expanded {
        let y = pixel / width
        // Same-row cheek sample preserves the original skin tone without touching hair.
        bitmap.setColor(bitmap.colorAt(x: 400, y: y)!, atX: pixel % width, y: y)
    }
}
try exportCutout("Hoodie-Blink")
print("Transparent hoodie and blink cutouts prepared; original artwork unchanged")
