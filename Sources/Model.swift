import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class Model: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selected: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(selected), forKey: "sessions")
            if let current, !selected.contains(current.sessionID), current.sessionID != "preview" { self.current = nil }
        }
    }
    @Published var sound: Bool { didSet { UserDefaults.standard.set(sound, forKey: "sound") } }
    @Published var paused = false { didSet { if paused { current = nil } } }
    @Published var connected = false
    @Published var problem: String?
    @Published var routingStatus: String?
    @Published var openingSession = false
    @Published var current: Notice? { didSet { if current == nil { autoExpanded = false } } }
    @Published var pending: [Notice] = []
    @Published var history: [Notice] = []
    @Published var hovered = false
    @Published var autoExpanded = false
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private var delivery = Delivery()
    private var working: [String: Notice] = [:]
    private var dismissed = Set<String>()
    private var expires: Double = 0
    private var expansionExpires: Double = 0
    private var lastSound: Double = 0
    private lazy var notificationSound: NSSound? = Bundle.main.url(forResource: "dyland-sound", withExtension: "mp3")
        .flatMap { NSSound(contentsOf: $0, byReference: false) }
    private var poll: Task<Void, Never>?
    var openSettings: (() -> Void)?

    init() {
        selected = Set(UserDefaults.standard.stringArray(forKey: "sessions") ?? [])
        sound = UserDefaults.standard.object(forKey: "sound") as? Bool ?? true
    }

    var expanded: Bool { hovered || (current != nil && autoExpanded) }
    var compactWorking: Bool { current?.kind == "working" && !expanded }
    var islandWidth: CGFloat { expanded ? max(440, notchWidth) : compactWorking ? notchWidth + 72 : current == nil ? notchWidth : max(270, notchWidth) }
    var islandHeight: CGFloat { compactWorking ? max(notchHeight, 28) : notchHeight + (expanded ? 100 : current == nil ? 0 : 48) }
    func setHovered(_ inside: Bool) {
        guard hovered != inside else { return }
        hovered = inside
        if !inside { autoExpanded = false }
    }
    func updateExpansion(now: Double) {
        if autoExpanded, now >= expansionExpires { autoExpanded = false }
    }
    var title: String { session(current?.sessionID)?.title ?? "Dyland Preview" }
    func session(_ id: String?) -> Session? { sessions.first { $0.id == id } }
    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    deinit { poll?.cancel() }
    func start() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let read = await Task.detached(priority: .utility) { Bridge.read() }.value
                guard !Task.isCancelled, self != nil else { return }
                self?.apply(read)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func apply(_ read: BridgeRead) {
        let now = Date().timeIntervalSince1970
        updateExpansion(now: now)
        let isConnected = !read.snapshots.isEmpty
        if connected != isConnected { connected = isConnected }
        if let problem = read.problem, self.problem != problem { self.problem = problem }
        guard connected else {
            if current != nil, paused || current?.kind == "working" { current = nil }
            if let current, !current.needsResponse, now > expires, !hovered { self.current = nil }
            return
        }
        var latest: [String: Session] = [:]
        for session in read.snapshots.flatMap(\.sessions) {
            if session.updatedAt >= (latest[session.id]?.updatedAt ?? 0) { latest[session.id] = session }
        }
        let sessions = latest.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        if self.sessions != sessions { self.sessions = sessions }
        let requests = Dictionary(read.snapshots.flatMap(\.pending).map { (pendingKey($0), $0) }, uniquingKeysWith: { a, b in a.timestamp <= b.timestamp ? a : b })
        let pending = requests.values.filter { selected.contains($0.sessionID) }.sorted {
            $0.timestamp == $1.timestamp ? pendingKey($0) < pendingKey($1) : $0.timestamp > $1.timestamp
        }
        if self.pending != pending { self.pending = pending }
        let fresh = delivery.consume(read.snapshots, selected: selected, now: now)
        working.removeAll()
        for notice in read.snapshots.flatMap(\.notices).sorted(by: { $0.timestamp < $1.timestamp }) {
            if notice.kind == "working" { working[notice.sessionID] = notice }
            else if notice.kind != "hook" { working.removeValue(forKey: notice.sessionID) }
        }
        dismissed.formIntersection(Set(pending.map(pendingKey)))
        if let current, current.kind == "working", working[current.sessionID] == nil { self.current = nil }
        for notice in fresh {
            guard notice.kind != "resolved" else { continue }
            if notice.kind != "working" {
                history.removeAll { $0.id == notice.id }
                history.insert(notice, at: 0)
                history = Array(history.prefix(30))
            }
        }
        if paused {
            if current != nil { current = nil }
            return
        }
        if let urgent = fresh.last(where: { $0.needsResponse }) {
            present(urgent, now: now, audible: true)
        } else if let update = fresh.last(where: { $0.kind != "resolved" && $0.kind != "working" }) {
            if current?.needsResponse == true { playSound(update, now: now) }
            else { present(update, now: now, audible: true) }
        }
        if let current, current.needsResponse, !pending.contains(where: { pendingKey($0) == pendingKey(current) }) {
            self.current = nil
        }
        if let current, !current.needsResponse, current.kind != "working", now > expires, !hovered { self.current = nil }
        if current == nil {
            if let awaiting = pending.first(where: { !dismissed.contains(pendingKey($0)) }) { present(awaiting, now: now, audible: false) }
            else if let active = working.values.filter({ selected.contains($0.sessionID) }).max(by: { $0.timestamp < $1.timestamp }), connected {
                current = active
            }
        }
    }
    private func present(_ notice: Notice, now: Double, audible: Bool) {
        current = notice
        autoExpanded = notice.kind != "working"
        expansionExpires = now + 3
        expires = now + 7
        if audible { playSound(notice, now: now) }
    }
    private func playSound(_ notice: Notice, now: Double) {
        guard ["done", "question", "permission", "error"].contains(notice.kind), sound, now - lastSound >= 2 else { return }
        guard let notificationSound else {
            problem = "The dyland-sound.mp3 sound is unavailable. Reinstall Dyland."
            return
        }
        notificationSound.play()
        lastSound = now
    }
    private func pendingKey(_ notice: Notice) -> String {
        [notice.sessionID, notice.kind, notice.requestID ?? notice.id].joined(separator: "|")
    }
    func dismiss() {
        if let current { dismissed.insert(pendingKey(current)) }
        current = nil
        hovered = false
    }
    func preview() {
        paused = false
        present(Notice(id: UUID().uuidString, sessionID: "preview", kind: "done", timestamp: Date().timeIntervalSince1970), now: Date().timeIntervalSince1970, audible: true)
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch { problem = "Failed to change launch at login: \(error.localizedDescription)" }
    }
    func openCurrent() {
        guard let current, let session = session(current.sessionID) else { openSettings?(); return }
        open(session)
    }
    func open(_ session: Session) {
        guard !openingSession else { return }
        openingSession = true
        routingStatus = "Opening session in Ghostty…"
        Task {
            defer { openingSession = false }
            do { routingStatus = try await TerminalRouter.open(session) }
            catch { routingStatus = nil; problem = error.localizedDescription; openSettings?() }
        }
    }
}
