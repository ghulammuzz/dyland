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

struct IslandView: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if model.compactWorking {
                    HStack(spacing: 0) {
                        // Symbol effects can starve AppKit's main queue in an accessory app.
                        TimelineView(.animation(minimumInterval: 0.4, paused: reduceMotion)) { context in
                            HStack(spacing: 3) {
                                ForEach(0..<3) { dot in
                                    Circle()
                                        .fill(.cyan.opacity(reduceMotion || Int(context.date.timeIntervalSince1970 / 0.4) % 3 == dot ? 1 : 0.35))
                                        .frame(width: 3, height: 3)
                                }
                            }
                        }
                        .frame(width: 36, height: model.islandHeight)
                        Color.clear.frame(width: model.notchWidth)
                        Color.clear.frame(width: 36)
                    }
                    .accessibilityLabel("Agent working")
                } else {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: model.notchHeight + (model.expanded ? 5 : 7))
                        if let notice = model.current {
                            HStack(spacing: 14) {
                                Image(systemName: notice.symbol)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(notice.tint)
                                    .frame(width: 34, height: 34)
                                    .background(notice.tint.opacity(0.16), in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(notice.label).font(.system(size: 13, weight: .semibold))
                                    if model.expanded {
                                        Text(model.title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.78)).lineLimit(1)
                                    }
                                }
                                if model.expanded {
                                    Spacer(minLength: 0)
                                    Button(action: model.dismiss) {
                                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .accessibilityLabel("Dismiss notification")
                                    .help("Dismiss notification; questions remain available in the menu")
                                }
                            }
                            .padding(.horizontal, 20)
                            if model.expanded {
                                HStack {
                                    Text(model.pending.count > 1 ? "\(model.pending.count) pending requests" : "OpenCode · Ghostty")
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                                }.padding(.horizontal, 22).padding(.top, 12)
                            }
                        } else if model.expanded {
                            HStack(spacing: 14) {
                                Image(systemName: "capsule.inset.filled")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Dyland").font(.system(size: 14, weight: .semibold))
                                    Text(model.paused ? "Notifications paused" : model.connected ? "\(model.selected.count) sessions monitored" : "Waiting for OpenCode")
                                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
                                }
                                Spacer()
                                Image(systemName: "gearshape").foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(.horizontal, 22)
                            Text("Click for sessions and settings")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                                .padding(.top, 12)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: model.islandWidth, height: model.islandHeight, alignment: .top)
            .clipped()
            .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24))
            .overlay {
                UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24)
                    .stroke(.white.opacity(contrast == .increased ? 0.8 : 0.12), lineWidth: 1)
            }
            .foregroundStyle(.white)
            .contentShape(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24))
            .onTapGesture { model.openCurrent() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.current.map { "\($0.label), \(model.title)" } ?? "Dyland, sessions and settings")
            .accessibilityAction(named: model.current == nil ? "Open settings" : "Open session in Ghostty", model.openCurrent)
            .accessibilityAction(named: "Dismiss", model.dismiss)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1), value: model.current?.id)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: model.expanded)
        .preferredColorScheme(.dark)
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var search = ""
    @State private var tab = 0
    var filtered: [Session] {
        model.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.directory.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        TabView(selection: $tab) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Pick sessions. Stay focused.").font(.title2.weight(.semibold))
                        Text("Only selected sessions appear in the island.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(model.connected ? "Connected" : "Waiting for plugin", systemImage: model.connected ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(model.connected ? Color.green : .secondary)
                        .font(.callout)
                }
                TextField("Search titles or project folders", text: $search).textFieldStyle(.roundedBorder)
                if filtered.isEmpty {
                    ContentUnavailableView(model.connected ? "No sessions" : "Connect OpenCode", systemImage: "terminal", description: Text(model.connected ? "Root sessions appear after you create them in OpenCode." : "Install the Dyland plugin, then open a project in OpenCode. See README for instructions."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { session in
                        HStack(spacing: 14) {
                            Toggle(isOn: Binding(get: { model.selected.contains(session.id) }, set: { _ in model.toggle(session.id) })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(session.title.isEmpty ? "Untitled session" : session.title).fontWeight(.medium).lineLimit(1)
                                        if let notice = model.pending.first(where: { $0.sessionID == session.id }) {
                                            Label(notice.label, systemImage: notice.symbol).font(.caption).foregroundStyle(.orange)
                                        }
                                    }
                                    Text(session.directory.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Monitor \(session.title)")
                            Button { model.open(session) } label: { Image(systemName: "arrow.up.right") }
                                .accessibilityLabel("Open \(session.title) in Ghostty").help("Open session in Ghostty")
                        }.padding(.vertical, 6)
                    }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text("\(model.selected.count) sessions monitored · New sessions are not selected automatically")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).tabItem { Label("Sessions", systemImage: "terminal") }.tag(0)

            Form {
                Section("Notifications") {
                    Toggle("Notification sound", isOn: $model.sound)
                    Toggle("Pause notifications", isOn: $model.paused)
                    Text("Sound plays for completions, questions, permissions, and errors. Limited to one sound every 2 seconds.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Preview Island and Sound", action: model.preview)
                }
                Section("Application") {
                    Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    Text("The island does not steal focus. Click to open a session in Ghostty. Animations respect macOS Reduce Motion.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("Bridge data stays local. Prompts, answers, and question details are not copied. The overlay displays session titles.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Bridge Folder") { NSWorkspace.shared.open(Bridge.root) }
                }
            }.formStyle(.grouped).tabItem { Label("Settings", systemImage: "gearshape") }.tag(1)
        }
        .safeAreaInset(edge: .bottom) {
            if let status = model.routingStatus {
                Label(status, systemImage: model.openingSession ? "clock" : "terminal")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if let problem = model.problem {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(problem).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.problem = nil }
                }.font(.callout).padding(12).background(.regularMaterial)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}
