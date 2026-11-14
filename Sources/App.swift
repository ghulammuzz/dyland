import AppKit
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    private var status: NSStatusItem!
    private var panel: IslandPanel!
    private var settings: NSWindow!
    private var pointerTimer: Timer?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var topInset: CGFloat = 0
    private var lastInside = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One menu-bar instance. Don't race bridge consumers or duplicate sounds.
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: "local.dyland.app")
        if copies.count > 1 { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        model.openSettings = { [weak self] in self?.showSettings() }
        makeMenu()
        makePanel()
        NotificationCenter.default.addObserver(self, selector: #selector(positionPanel), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateHitRegion()
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateHitRegion()
            return event
        }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHitRegion() }
        }
        pointerTimer?.tolerance = 0.02
        model.start()
        if !UserDefaults.standard.bool(forKey: "launched") {
            UserDefaults.standard.set(true, forKey: "launched")
            showSettings()
        }
        if CommandLine.arguments.contains("--preview") { showSettings(); model.preview() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    private func makeMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "capsule.inset.filled", accessibilityDescription: "Dyland")
        let menu = NSMenu()
        add(menu, "Sessions and Settings…", #selector(showSettings), ",")
        add(menu, "Preview Island", #selector(preview), "")
        add(menu, "Pause / Resume Notifications", #selector(togglePause), "")
        menu.addItem(.separator())
        add(menu, "Open Last Notification", #selector(openLast), "")
        menu.addItem(.separator())
        add(menu, "Quit Dyland", #selector(quit), "q")
        status.menu = menu
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = menu.copy() as? NSMenu
        main.addItem(app)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
    private func makePanel() {
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        positionPanel()
        panel.orderFrontRegardless()
    }
    @objc private func willSleep() {
        model.suspendSpotify()
        model.setHovered(false)
    }
    @objc private func didWake() {
        positionPanel()
        model.startSpotify()
    }
    @objc private func positionPanel() {
        guard panel != nil, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        let safeTop = screen.safeAreaInsets.top
        model.hasNotch = safeTop > 0
        model.notchHeight = safeTop > 0 ? safeTop : 0
        topInset = safeTop > 0 ? 0 : 6
        var centerX = screen.frame.midX
        model.notchWidth = 180
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            centerX = (left.maxX + right.minX) / 2
            model.notchWidth = max(180, right.minX - left.maxX)
        }
        let width = max(480, model.notchWidth + 112)
        let height = max(300, model.notchHeight + 240)
        panel.setFrame(NSRect(x: centerX - width / 2, y: screen.frame.maxY - height - topInset, width: width, height: height), display: true)
    }
    private func updateHitRegion() {
        guard let panel else { return }
        let geometry = model.islandGeometry
        let width = geometry?.width ?? model.islandWidth
        let height = geometry?.height ?? model.islandHeight
        let rect = NSRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY - height, width: width, height: height)
        let pointer = NSEvent.mouseLocation
        guard rect.contains(pointer) else {
            if model.hovered && Date().timeIntervalSince(lastInside) >= 0.18 { model.setHovered(false) }
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        let local = CGPoint(x: pointer.x - rect.minX, y: rect.maxY - pointer.y)
        var shape = IslandSilhouette(notched: model.hasNotch, expanded: model.expanded)
        if let geometry { shape.shoulder = geometry.shoulder; shape.radius = geometry.radius }
        let inside = shape.path(in: CGRect(origin: .zero, size: rect.size)).contains(local)
        let now = Date()
        if inside { lastInside = now }
        model.setHovered(inside || (model.hovered && now.timeIntervalSince(lastInside) < 0.18))
        let physicalNotch = model.hasNotch && pointer.y >= panel.frame.maxY - model.notchHeight && abs(pointer.x - panel.frame.midX) < model.notchWidth / 2
        let ignoresMouse = !inside || physicalNotch
        if panel.ignoresMouseEvents != ignoresMouse { panel.ignoresMouseEvents = ignoresMouse }
    }
    @objc func showSettings() {
        if settings == nil {
            settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            settings.title = "Dyland"
            settings.isReleasedWhenClosed = false
            settings.delegate = self
            settings.contentView = NSHostingView(rootView: SettingsView(model: model))
            settings.center()
            settings.setFrameAutosaveName("DylandSettings")
        }
        settings.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settings else { return }
        window.contentView = nil
        settings = nil
    }
    @objc private func preview() { model.preview() }
    @objc private func togglePause() { model.paused.toggle() }
    @objc private func openLast() {
        if model.current != nil { model.openCurrent() }
        else if let notice = model.pending.first ?? model.history.first, let session = model.session(notice.sessionID) { model.open(session) }
        else { showSettings() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct Dyland {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-check") { spotifySelfCheck(); selfCheck(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
