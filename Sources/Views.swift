import SwiftUI

extension Notice {
    var tint: Color {
        switch kind {
        case "done": .green
        case "error": .red
        case "question", "permission": .orange
        default: .cyan
        }
    }
}

// Concave shoulders join the physical notch; external displays use a detached capsule.
struct IslandSilhouette: Shape {
    var notched: Bool
    var shoulder: CGFloat
    var radius: CGFloat

    init(notched: Bool, expanded: Bool) {
        self.notched = notched
        shoulder = notched ? (expanded ? 18 : 6) : 0
        radius = expanded ? 24 : notched ? 14 : 16
    }
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, radius) }
        set { shoulder = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        guard notched else { return RoundedRectangle(cornerRadius: radius).path(in: rect) }
        let s = shoulder
        let r = min(radius, rect.height / 2)
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: s, y: s), control: CGPoint(x: s, y: 0))
        p.addLine(to: CGPoint(x: s, y: h - r))
        p.addQuadCurve(to: CGPoint(x: s + r, y: h), control: CGPoint(x: s, y: h))
        p.addLine(to: CGPoint(x: w - s - r, y: h))
        p.addQuadCurve(to: CGPoint(x: w - s, y: h - r), control: CGPoint(x: w - s, y: h))
        p.addLine(to: CGPoint(x: w - s, y: s))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - s, y: 0))
        p.closeSubpath()
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

struct IslandGeometry {
    let width: CGFloat
    let height: CGFloat
    let shoulder: CGFloat
    let radius: CGFloat
}

private struct IslandSurface: AnimatableModifier {
    let model: Model
    let highContrast: Bool
    var width: CGFloat
    var height: CGFloat
    var shoulder: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(shoulder, radius)) }
        set { width = newValue.first.first; height = newValue.first.second; shoulder = newValue.second.first; radius = newValue.second.second }
    }
    func body(content: Content) -> some View {
        var shape = IslandSilhouette(notched: model.hasNotch, expanded: model.expanded)
        shape.shoulder = shoulder
        shape.radius = radius
        // Non-published presentation geometry keeps AppKit click-through aligned with every animation frame.
        model.islandGeometry = IslandGeometry(width: width, height: height, shoulder: shoulder, radius: radius)
        return content
            .frame(width: width, height: height, alignment: .top)
            .background(.black, in: shape)
            .overlay { shape.stroke(.white.opacity(highContrast ? 0.7 : model.expanded ? 0.07 : 0), lineWidth: 1) }
            .clipShape(shape)
    }
}

struct IslandView: View {
    @ObservedObject var model: Model
    @State private var hoveredRow: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var silhouette: IslandSilhouette { IslandSilhouette(notched: model.hasNotch, expanded: model.expanded) }
    private var status: String {
        if model.showingSpotify, let song = model.spotify { return "\(song.title) · \(song.artist)" }
        if model.islandActivityCount > 1 {
            return model.current?.needsResponse == true ? "Needs your attention" : "Agents working"
        }
        return model.current?.label ?? (model.paused ? "Notifications paused" : model.connected ? "All quiet" : "Waiting for OpenCode")
    }
    private var tint: Color {
        guard let current = model.current, current.needsResponse || current.kind == "error" else { return .white.opacity(0.85) }
        return current.tint
    }
    private var count: Int { model.islandActivityCount }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.showingSpotify {
                    if model.hasNotch && model.expanded { Color.clear.frame(height: model.islandHeaderHeight) }
                    spotifyPanel
                } else {
                    if model.hasNotch && (model.current == nil || model.expanded) {
                        Color.clear.frame(height: model.islandHeaderHeight)
                    } else if model.hasNotch || !model.expanded { compactBar }
                    if model.expanded {
                        panel
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }
            }
            .modifier(IslandSurface(model: model, highContrast: contrast == .increased, width: model.islandWidth, height: model.islandHeight, shoulder: silhouette.shoulder, radius: silhouette.radius))
            .shadow(color: .black.opacity(model.expanded ? 0.28 : 0), radius: 12, y: 6)
            .foregroundStyle(.white)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Dyland, \(status)")
            .accessibilityAction(named: "Open sessions and settings") { model.openSettings?() }
            .accessibilityAction(named: "Dismiss notification", model.dismiss)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 1), value: model.expanded)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 1), value: model.islandHeight)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 1), value: model.islandWidth)
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.22), value: model.current?.id)
        .preferredColorScheme(.dark)
    }

    private var spotifyPanel: some View {
        Button(action: model.openCurrent) {
            VStack(spacing: model.expanded ? 12 : 0) {
                HStack(spacing: 10) {
                    AsyncImage(url: model.spotify?.artwork) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.12))
                    }
                    .frame(width: model.expanded ? 44 : 22, height: model.expanded ? 44 : 22)
                    .clipShape(RoundedRectangle(cornerRadius: model.expanded ? 7 : 4))
                    if model.hasNotch && !model.expanded {
                        Color.clear.frame(width: model.notchWidth + 12)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.spotify?.title ?? "Spotify").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if model.expanded {
                                Text(model.spotify?.artist ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    Image(systemName: model.spotify?.playing == true ? "waveform" : "pause.fill")
                        .font(.system(size: 12)).foregroundStyle(.green)
                }
                .frame(height: model.expanded ? 44 : model.islandHeaderHeight)
                if !model.spotifyCaption.isEmpty {
                    Text(model.spotifyCaption)
                        .font(.system(size: model.expanded ? 15 : 12, weight: .medium))
                        .lineLimit(model.expanded ? 2 : 1)
                        .frame(maxWidth: .infinity, minHeight: model.expanded ? 48 : 32)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(model.spotify?.playing == true ? 0.95 : 0.5))
                }
            }
            .padding(.horizontal, model.expanded ? 30 : 18)
            .padding(.vertical, model.expanded ? 16 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(status). \(model.spotifyCaption). Open Spotify")
        .help("Open Spotify")
    }

    private var compactBar: some View {
        Button(action: model.openCurrent) {
            HStack(spacing: 0) {
                DylandMark(kind: model.current?.kind ?? (model.paused ? "paused" : nil), attentive: model.hovered, animating: !model.expanded, style: model.mascot)
                    .frame(width: 26, height: model.mascot == .hoodie ? 26 : 18)
                    .frame(maxWidth: .infinity, alignment: model.hasNotch ? .trailing : .leading)
                if model.hasNotch {
                    Color.clear.frame(width: model.notchWidth + 20)
                } else {
                    Text(model.current == nil ? "Dyland" : status)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 10)
                }
                HStack(spacing: 5) {
                    if model.current?.kind == "working" && !model.expanded { workingIndicator }
                    else { Image(systemName: model.current?.symbol ?? (model.paused ? "pause.fill" : "minus")) }
                    if count > 1 { Text(count > 99 ? "99+" : String(count)).monospacedDigit() }
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: model.hasNotch ? .leading : .trailing)
            }
            .padding(.horizontal, model.hasNotch ? 14 : 16)
            .frame(height: model.islandHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.openingSession)
        .opacity(model.expanded ? 0 : 1)
        .allowsHitTesting(!model.expanded)
        .accessibilityHidden(model.expanded)
        .accessibilityLabel("\(status). Open \(model.current == nil ? "settings" : model.terminal.rawValue)")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    DylandMark(kind: model.current?.kind ?? (model.paused ? "paused" : nil), attentive: model.hovered, style: model.mascot)
                        .frame(width: 22, height: model.mascot == .hoodie ? 25 : 18)
                    Text(model.current == nil ? "Dyland" : status)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                }
                Spacer()
                Button { model.openSettings?() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                .help("Sessions and settings").accessibilityLabel("Open sessions and settings")
                if model.current != nil {
                    Button(action: model.dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                    .help("Dismiss; pending requests remain in Sessions").accessibilityLabel("Dismiss notification")
                }
            }.frame(height: 24)
            VStack(spacing: 0) {
                if model.current == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status).font(.system(size: 13, weight: .medium))
                        Text(model.connected ? "\(model.monitoredCount) sessions monitored" : "Open a project in OpenCode to connect.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else {
                    ForEach(model.islandNotices) { notice in sessionRow(notice) }
                }
            }
        }
        .padding(.horizontal, model.hasNotch ? 38 : 20).padding(.vertical, 12)
    }

    private func sessionRow(_ notice: Notice) -> some View {
        let session = model.session(notice.sessionID)
        let title = session.map { $0.title.isEmpty ? "Untitled session" : $0.title } ?? "Dyland preview"
        let folder = session.map { URL(fileURLWithPath: $0.directory).lastPathComponent } ?? "Notification preview"
        let detail = notice.kind == model.current?.kind ? folder : "\(folder) · \(notice.label)"
        return Button {
            if let session { model.open(session) } else { model.openSettings?() }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: model.openingSession ? "clock" : "arrow.up.right")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 8)
            .background(.white.opacity(hoveredRow == notice.id ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, -8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(model.openingSession)
        .onHover { hoveredRow = $0 ? notice.id : nil }
        .accessibilityLabel("\(title), \(notice.label). Open in \(model.terminal.rawValue)")
        .help("\(notice.label). Open in \(model.terminal.rawValue)")
    }

    private var workingIndicator: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            HStack(spacing: 3) {
                ForEach(0..<3) { dot in
                    Circle().frame(width: 3, height: 3)
                        .opacity(reduceMotion ? 0.7 : 0.3 + 0.55 * (1 + cos(context.date.timeIntervalSince1970 * .pi * 2 / 1.5 - Double(dot) * .pi * 2 / 3)) / 2)
                }
            }
            .frame(width: 15, height: 11)
        }
        .accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var search = ""
    @State private var tab = 0
    @State private var filter = 0

    init(model: Model, initialTab: Int = 0) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    private var filtered: [Session] {
        model.sessions.filter { session in
            let matches = search.isEmpty || session.title.localizedCaseInsensitiveContains(search) || session.directory.localizedCaseInsensitiveContains(search)
            return matches && (filter == 0 || (filter == 1 && model.selected.contains(session.id)) || (filter == 2 && model.pending.contains { $0.sessionID == session.id }))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    DylandMark(kind: nil, animating: false, style: model.mascot).frame(width: 30, height: 22)
                    Text("Dyland").font(.title3.weight(.semibold))
                }.padding(.horizontal, 18).padding(.top, 22)
                VStack(spacing: 4) {
                    navigation("Sessions", symbol: "square.stack", destination: 0)
                    navigation("General", symbol: "gearshape", destination: 1)
                }.padding(.horizontal, 10)
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.connected ? "Connected to OpenCode" : "OpenCode disconnected", systemImage: model.connected ? "checkmark.circle" : "network.slash")
                    if model.paused { Label("Notifications paused", systemImage: "pause.circle") }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 18)
            }
            .frame(width: 190).frame(maxHeight: .infinity)
            .background(.bar)
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tab == 0 ? "Sessions" : "General")
                            .font(.system(size: 24, weight: .semibold))
                        Text(tab == 0 ? "Choose which sessions appear in your island." : "Manage notifications and app preferences.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(action: model.preview) { Label("Preview", systemImage: "play.fill") }
                        .help("Preview the island and notification sound")
                }
                if tab == 0 { sessions } else { settings }
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let status = model.routingStatus {
                    Label(status, systemImage: model.openingSession ? "clock" : "terminal")
                        .textSelection(.enabled).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                if let problem = model.problem {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text(problem).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { model.problem = nil }
                    }.font(.callout).padding(12)
                }
            }.background(.regularMaterial)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private func navigation(_ title: String, symbol: String, destination: Int) -> some View {
        Button { tab = destination } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: tab == destination ? .medium : .regular))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(tab == destination ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == destination ? .isSelected : [])
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                metric("Monitored", count: model.monitoredCount, symbol: "eye", tint: .secondary)
                Divider().frame(height: 28)
                metric("Working", count: model.workingCount, symbol: "ellipsis", tint: .secondary)
                Divider().frame(height: 28)
                metric("Needs attention", count: model.attentionCount, symbol: "hand.raised", tint: model.attentionCount > 0 ? .orange : .secondary)
            }
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sessions or folders", text: $search)
                    .textFieldStyle(.plain).accessibilityLabel("Search sessions or project folders")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .padding(9)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            Picker("Show sessions", selection: $filter) {
                Text("All").tag(0)
                Text("Monitored").tag(1)
                Text("Needs attention").tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    emptyState
                    if !search.isEmpty || filter != 0 {
                        Button("Show all sessions") { search = ""; filter = 0 }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !model.connected {
                    Label("Bridge disconnected. Showing last known sessions.", systemImage: "network.slash")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { session in
                            sessionCard(session)
                            Divider().padding(.leading, 44)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Text("New sessions stay unmonitored until you select them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, count: Int, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(count, format: .number).font(.title2.weight(.semibold)).monospacedDigit()
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(count)")
    }

    private func sessionCard(_ session: Session) -> some View {
        let title = session.title.isEmpty ? "Untitled session" : session.title
        let activity = model.activity(for: session.id)
        let tint: Color = activity.map { $0.needsResponse || $0.kind == "error" ? $0.tint : .secondary } ?? .secondary
        let status = activity.map { ["done", "error", "interrupted"].contains($0.kind) ? "Last: \($0.label)" : $0.label } ?? "No activity yet"
        return HStack(alignment: .center, spacing: 12) {
            Toggle("Monitor \(title)", isOn: Binding(get: { model.selected.contains(session.id) }, set: { _ in model.toggle(session.id) }))
                .toggleStyle(.checkbox).labelsHidden().help("Monitor \(title)")
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Label(session.directory.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"), systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(session.directory)
                HStack(spacing: 8) {
                    Label {
                        Text(status).foregroundStyle(tint)
                    } icon: {
                        Image(systemName: activity?.symbol ?? "minus.circle").foregroundStyle(tint)
                    }
                        .font(.caption)
                    Spacer(minLength: 0)
                    Text(Date(timeIntervalSince1970: activity?.timestamp ?? session.updatedAt), format: .dateTime.hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Last updated \(Date(timeIntervalSince1970: activity?.timestamp ?? session.updatedAt).formatted())")
                }
            }
            Spacer(minLength: 0)
            Button { model.open(session) } label: { Image(systemName: "arrow.up.right") }
                .disabled(model.openingSession)
                .accessibilityLabel("Open \(title) in \(model.terminal.rawValue)")
                .help("Open session in \(model.terminal.rawValue)")
        }
        .padding(14)
    }

    private var emptyState: some View {
        let title = !search.isEmpty ? "No matching sessions" : !model.connected ? "Connect OpenCode" : filter == 1 ? "Nothing monitored yet" : filter == 2 ? "All clear" : "No sessions yet"
        let detail = !search.isEmpty ? "Try another title or project folder, or change the filter." : !model.connected ? "Install the Dyland plugin, then open a project in OpenCode. See README for instructions." : filter == 1 ? "Choose All, then select the sessions you want in the island." : filter == 2 ? "No pending questions or permission requests." : "Root sessions appear here when you create them in OpenCode."
        return ContentUnavailableView(title, systemImage: filter == 2 && model.connected ? "checkmark.circle" : "terminal", description: Text(detail))
    }

    private var settings: some View {
        Form {
            Section("Appearance") {
                Picker("Mascot", selection: $model.mascot) {
                    ForEach(MascotStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                HStack(spacing: 12) {
                    DylandMark(kind: "working", animating: false, style: model.mascot)
                        .frame(width: 36, height: model.mascot == .hoodie ? 41 : 28)
                    Text("Changes apply immediately. All mascots use the same subtle eye animations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Notifications") {
                Toggle("Notification sound", isOn: $model.sound)
                Toggle("Pause notifications", isOn: $model.paused)
                Text("Sound plays for completions, questions, permissions, and errors. Limited to one sound every 2 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spotify") {
                Toggle("Spotify lyrics", isOn: $model.spotifyEnabled)
                Text("Reads Spotify desktop playback using macOS Automation. Sends song title, artist, album, and duration to LRCLIB for synced lyrics. OpenCode notifications take priority over music.")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem = model.spotifyProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Section("Open sessions") {
                Picker("Terminal", selection: $model.terminal) {
                    ForEach(TerminalRouter.Terminal.allCases, id: \.self) { terminal in
                        Text(terminal.rawValue).tag(terminal)
                    }
                }
                if model.terminal == .warp {
                    Text("Warp opens a new tab for each click and requires Tab Config support. Existing Warp tabs are not focused.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Click an island session to open it in \(model.terminal.rawValue).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup & accessibility") {
                Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                Text("The island never steals keyboard focus. Animations follow the macOS Reduce Motion setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Bridge data stays local. Prompts, answers, and question details are not copied. The overlay displays session titles.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Bridge Folder") { NSWorkspace.shared.open(Bridge.root) }
            }
        }.formStyle(.grouped)
    }
}
