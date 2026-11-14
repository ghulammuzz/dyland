// Run from the repository root:
// swiftc -parse-as-library Sources/{Bridge,DylandMark,Model,TerminalRouter,Views}.swift scripts/check-settings.swift -o "$TMPDIR/dyland-settings-check" && "$TMPDIR/dyland-settings-check"
import AppKit
import SwiftUI

@main
struct SettingsCheck {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Preview data must never overwrite the user's preferences.
        UserDefaults.standard.setVolatileDomain([
            "sessions": ["design", "review"],
            "mascot": CommandLine.arguments.contains("--ghost") ? "ghost" : "capsule",
        ], forName: UserDefaults.argumentDomain)
        let model = Model()
        let now = Date().timeIntervalSince1970
        let sessions = [
            Session(id: "design", title: "Refine the island animation", directory: "/Users/demo/Projects/dyland", updatedAt: now),
            Session(id: "review", title: "Review authentication flow", directory: "/Users/demo/Projects/backend", updatedAt: now - 90),
            Session(id: "docs", title: "Update the getting started guide", directory: "/Users/demo/Projects/docs", updatedAt: now - 300),
        ]
        let working = Notice(id: "work", sessionID: "design", kind: "working", timestamp: now)
        let permission = Notice(id: "approval", sessionID: "review", kind: "permission", timestamp: now - 90)
        model.apply(BridgeRead(snapshots: [Snapshot(version: 1, updatedAt: now, sessions: sessions, notices: [working], pending: [permission])]))
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first(where: { $0 != "--ghost" }) ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, width, height, scheme, tab) in [
            ("settings", 880.0, 660.0, ColorScheme.dark, 0),
            ("settings-light", 760.0, 560.0, ColorScheme.light, 0),
            ("settings-large", 1100.0, 800.0, ColorScheme.dark, 0),
            ("general", 880.0, 660.0, ColorScheme.dark, 1),
            ("general-light", 760.0, 560.0, ColorScheme.light, 1),
        ] {
            let view = NSHostingView(rootView: SettingsView(model: model, initialTab: tab).environment(\.colorScheme, scheme))
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
            precondition(view.bounds.width == width && view.bounds.height == height, "Settings must fill the window")
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render settings") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode settings") }
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
        print("Settings layout check passed; previews: \(output.path)")
    }
}
