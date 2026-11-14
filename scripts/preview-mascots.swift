// Run from the repository root: swift scripts/preview-mascots.swift
import AppKit
import SwiftUI

struct Candidate: Identifiable {
    let id: String
    let name: String
    let filename: String
    var image: NSImage {
        guard let image = NSImage(contentsOfFile: "docs/mascots/\(filename).svg") else {
            fatalError("Missing candidate: \(filename)")
        }
        return image
    }
}

let candidates = [
    Candidate(id: "A1", name: "Capsule · neutral", filename: "A1-capsule"),
    Candidate(id: "B1", name: "Ghost · lilac", filename: "B1-ghost"),
    Candidate(id: "C1", name: "Owl · warm", filename: "C1-owl"),
    Candidate(id: "A2", name: "Pebble · sage", filename: "A2-pebble"),
    Candidate(id: "B2", name: "Ghost · ivory", filename: "B2-ghost"),
    Candidate(id: "C2", name: "Owl · slate", filename: "C2-owl"),
]

struct CandidateCard: View {
    let candidate: Candidate
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(candidate.id).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(candidate.name).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Image(nsImage: candidate.image).resizable().frame(width: 180, height: 180)
                .frame(maxWidth: .infinity)
            HStack(spacing: 20) {
                ForEach([20, 24, 32], id: \.self) { size in
                    HStack(spacing: 6) {
                        Image(nsImage: candidate.image).resizable().frame(width: CGFloat(size), height: CGFloat(size))
                        Text("\(size)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 36)
        }
        .padding(16).frame(maxWidth: .infinity)
        .background(Color(red: 23 / 255, green: 25 / 255, blue: 28 / 255))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let view = NSHostingView(rootView:
    VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 7) {
            Text("Dyland / mascot study").font(.system(size: 25, weight: .semibold))
            Text("Original vector concepts · 3 directions, 6 variants · small-size checks below each mark")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.bottom, 6)
        HStack(spacing: 16) { ForEach(Array(candidates.prefix(3))) { CandidateCard(candidate: $0) } }
        HStack(spacing: 16) { ForEach(Array(candidates.suffix(3))) { CandidateCard(candidate: $0) } }
        Text("A1 selected for Dyland. Original concept assets preserved.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }
    .padding(28)
    .frame(width: 960, height: 740, alignment: .topLeading)
    .background(Color(red: 0.055, green: 0.06, blue: 0.07))
    .foregroundStyle(.white)
    .environment(\.colorScheme, .dark)
)
view.appearance = NSAppearance(named: .darkAqua)
view.frame = NSRect(x: 0, y: 0, width: 960, height: 740)
let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = view
view.layoutSubtreeIfNeeded()
guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render preview") }
view.cacheDisplay(in: view.bounds, to: bitmap)
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode preview") }
try png.write(to: URL(fileURLWithPath: "docs/mascots/preview.png"))
print("Rendered docs/mascots/preview.png")
