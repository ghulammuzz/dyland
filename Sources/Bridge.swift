import AppKit
import Combine

struct Session: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
    let updatedAt: Double
}

struct Notice: Codable, Identifiable, Equatable {
    let id: String
    let sessionID: String
    let kind: String
    let timestamp: Double
    var requestID: String?

    var label: String {
        switch kind {
        case "working": "Agent working"
        case "done": "Turn complete"
        case "question": "Answer needed"
        case "permission": "Approval needed"
        case "error": "Session error"
        case "interrupted": "Session interrupted"
        default: "Hook triggered"
        }
    }
    var symbol: String {
        switch kind {
        case "working": "ellipsis"
        case "done": "checkmark"
        case "question": "questionmark"
        case "permission": "hand.raised.fill"
        case "error": "exclamationmark"
        case "interrupted": "stop.fill"
        default: "bolt.fill"
        }
    }
    var needsResponse: Bool { kind == "question" || kind == "permission" }
}

struct Snapshot: Decodable {
    let version: Int
    let updatedAt: Double
    let sessions: [Session]
    let notices: [Notice]
    let pending: [Notice]
}

struct BridgeRead: Sendable {
    var snapshots: [Snapshot] = []
    var problem: String?
}

extension Session: Sendable {}
extension Notice: Sendable {}
extension Snapshot: Sendable {}

enum Bridge {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Dyland", isDirectory: true)
    static let directory = root.appendingPathComponent("bridge", isDirectory: true)

    static func read(now: Double = Date().timeIntervalSince1970) -> BridgeRead {
        var result = BridgeRead()
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
            for file in files where file.pathExtension == "json" {
                do {
                    let resource = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                    guard resource.isSymbolicLink != true, (resource.fileSize ?? 0) <= 2_000_000 else { continue }
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
                    guard snapshot.version == 1, snapshot.updatedAt > now - 40, snapshot.updatedAt < now + 10 else { continue }
                    result.snapshots.append(snapshot)
                } catch {
                    result.problem = "Cannot read bridge data. Check the Dyland plugin."
                }
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Plugin has not started yet.
        } catch {
            result.problem = "Cannot read the bridge folder. Check folder permissions."
        }
        return result
    }
}

// Pure reducer shared by app and runnable --self-check.
struct Delivery {
    var seen = Set<String>()
    let startedAt = Date().timeIntervalSince1970
    var booted = false
    mutating func consume(_ snapshots: [Snapshot], selected: Set<String>, now: Double) -> [Notice] {
        let notices = snapshots.flatMap(\.notices).sorted { $0.timestamp < $1.timestamp }
        var fresh: [Notice] = []
        for notice in notices {
            let isNew = seen.insert(notice.id).inserted
            if (booted || notice.timestamp > startedAt) && isNew && selected.contains(notice.sessionID) && notice.timestamp > now - 15 && notice.timestamp <= now + 10 {
                fresh.append(notice)
            }
        }
        // Don't treat pre-existing completions as new notifications at launch.
        if !snapshots.isEmpty { booted = true }
        if !snapshots.isEmpty {
            let retained = Set(notices.map(\.id))
            seen.formIntersection(retained)
        }
        return fresh
    }
}

@MainActor
func selfCheck() {
    let now = Date().timeIntervalSince1970
    func snapshot(_ notices: [Notice]) -> Snapshot {
        Snapshot(version: 1, updatedAt: now, sessions: [], notices: notices, pending: [])
    }
    let done = Notice(id: "1", sessionID: "ses_test", kind: "done", timestamp: now)
    let question = Notice(id: "2", sessionID: "ses_test", kind: "question", timestamp: now)
    var delivery = Delivery()
    precondition(delivery.consume([snapshot([done])], selected: ["ses_test"], now: now).isEmpty)
    precondition(delivery.consume([snapshot([done, question]), snapshot([question])], selected: ["ses_test"], now: now) == [question])
    precondition(delivery.consume([snapshot([done, question])], selected: ["ses_test"], now: now).isEmpty)
    let ignored = Notice(id: "3", sessionID: "ses_other", kind: "done", timestamp: now)
    precondition(delivery.consume([snapshot([ignored])], selected: ["ses_test"], now: now).isEmpty)
    let old = Notice(id: "4", sessionID: "ses_test", kind: "done", timestamp: now - 60)
    precondition(delivery.consume([snapshot([old])], selected: ["ses_test"], now: now).isEmpty)
    precondition(question.needsResponse && !done.needsResponse)
    precondition(delivery.consume([], selected: ["ses_test"], now: now).isEmpty)
    var delayed = Delivery()
    _ = delayed.consume([], selected: ["ses_test"], now: now)
    let afterLaunch = Notice(id: "late", sessionID: "ses_test", kind: "done", timestamp: Date().timeIntervalSince1970 + 0.01)
    precondition(delayed.consume([snapshot([afterLaunch])], selected: ["ses_test"], now: now) == [afterLaunch])
    let defaults = UserDefaults.standard
    let saved = defaults.dictionaryRepresentation()
    let model = Model()
    model.selected = ["ses_test"]
    model.sound = false
    precondition(!model.expanded && model.islandWidth == model.notchWidth)
    model.setHovered(true)
    precondition(model.expanded && model.islandWidth == 440)
    model.setHovered(false)
    precondition(!model.expanded)
    model.current = Notice(id: "working-layout", sessionID: "ses_test", kind: "working", timestamp: now)
    precondition(model.compactWorking && model.islandHeight == model.notchHeight)
    precondition(model.islandWidth == model.notchWidth + 72)
    model.setHovered(true)
    precondition(!model.compactWorking && model.expanded && model.islandHeight == model.notchHeight + 100)
    model.setHovered(false)
    precondition(model.compactWorking)
    model.notchHeight = 8
    precondition(model.islandHeight == 28)
    model.notchHeight = 32
    model.preview()
    precondition(!model.compactWorking && model.expanded)
    model.updateExpansion(now: now + 4)
    precondition(!model.expanded && model.current != nil)
    model.setHovered(true)
    model.setHovered(false)
    model.setHovered(true)
    precondition(model.expanded)
    model.dismiss()
    model.apply(BridgeRead(snapshots: [snapshot([])]))
    let waiting = Snapshot(version: 1, updatedAt: now, sessions: [], notices: [question], pending: [question])
    model.apply(BridgeRead(snapshots: [waiting]))
    precondition(model.current?.kind == "question" && model.expanded)
    model.setHovered(true)
    model.setHovered(false)
    precondition(!model.expanded && model.current?.needsResponse == true)
    model.dismiss()
    model.apply(BridgeRead())
    model.apply(BridgeRead(snapshots: [waiting]))
    precondition(model.current == nil && model.pending.count == 1)
    model.apply(BridgeRead(snapshots: [snapshot([])]))
    precondition(model.pending.isEmpty)
    let active = Notice(id: "execution-start", sessionID: "ses_test", kind: "working", timestamp: now)
    model.apply(BridgeRead(snapshots: [snapshot([active])]))
    precondition(model.compactWorking)
    let completed = Notice(id: "execution-done", sessionID: "ses_test", kind: "done", timestamp: now)
    model.apply(BridgeRead(snapshots: [snapshot([active, completed])]))
    precondition(model.current == completed && model.expanded && !model.compactWorking)
    precondition(model.history.first == completed)
    model.apply(BridgeRead(snapshots: [snapshot([active, completed])]))
    precondition(model.history.filter { $0.id == completed.id }.count == 1)
    model.paused = true
    model.apply(BridgeRead(snapshots: [snapshot([done])]))
    precondition(model.current == nil)
    model.paused = false
    let stable = BridgeRead(snapshots: [Snapshot(version: 1, updatedAt: now,
        sessions: [Session(id: "ses_test", title: "Test", directory: "/Projects/test", updatedAt: now)],
        notices: [], pending: [])])
    model.apply(stable)
    var publications = 0
    let observation = model.objectWillChange.sink { publications += 1 }
    for _ in 0..<100 { model.apply(stable) }
    precondition(publications == 0, "Unchanged bridge reads must not invalidate SwiftUI")
    model.paused = true
    publications = 0
    for _ in 0..<100 { model.apply(stable) }
    precondition(publications == 0, "Paused bridge reads must not invalidate SwiftUI")
    model.apply(BridgeRead())
    publications = 0
    for _ in 0..<100 { model.apply(BridgeRead()) }
    precondition(publications == 0, "Disconnected bridge reads must not invalidate SwiftUI")
    observation.cancel()
    for key in ["sessions", "sound"] {
        if let old = saved[key] { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    do { try TerminalRouter.selfCheck() }
    catch { fatalError("TerminalRouter self-check failed: \(error)") }
    if Bundle.main.bundleURL.pathExtension == "app" {
        guard let iconURL = Bundle.main.url(forResource: "Dyland", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL), !icon.representations.isEmpty else {
            fatalError("Bundled Dyland.icns missing or invalid")
        }
        guard let url = Bundle.main.url(forResource: "dyland-sound", withExtension: "mp3"),
              let sound = NSSound(contentsOf: url, byReference: false), sound.duration > 0 else {
            fatalError("Bundled dyland-sound.mp3 missing or invalid")
        }
    }
    print("Dyland self-check passed")
}
