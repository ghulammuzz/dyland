// Run from the repo root on macOS:
// swiftc -parse-as-library Sources/{Bridge,DylandMark,Model,TerminalRouter,Views}.swift scripts/check-island.swift -o "$TMPDIR/dyland-island-check" && "$TMPDIR/dyland-island-check"
import AppKit
import SwiftUI

@main struct IslandCheck {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = Model()
        model.current = Notice(id: "preview", sessionID: "preview", kind: "working", timestamp: 0)
        let view = NSHostingView(rootView: IslandView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let compactWidth = model.islandWidth
        model.setHovered(true)
        var widths: [CGFloat] = []
        for _ in 0..<40 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if let geometry = model.islandGeometry { widths.append(geometry.width) }
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(widths.contains { $0 > compactWidth + 1 && $0 < model.islandWidth - 1 },
                         "Click-through geometry must track intermediate animation frames")
        }
        precondition(abs((widths.last ?? 0) - model.islandWidth) < 1, "Geometry must settle at expanded width")
        model.hasNotch = false
        model.setHovered(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        precondition(abs((model.islandGeometry?.height ?? 0) - 32) < 1, "External compact capsule must settle at 32 points")
        print("Island presentation geometry check passed")
    }
}
