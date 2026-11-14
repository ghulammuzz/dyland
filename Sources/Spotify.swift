import AppKit
import Foundation

struct LyricLine: Equatable {
    let time: Double
    let text: String

    static func parse(_ lrc: String) -> [LyricLine] {
        let pattern = #/\[(\d+):(\d{2}(?:\.\d+)?)\]/#
        return lrc.components(separatedBy: .newlines).flatMap { row -> [LyricLine] in
            let matches = Array(row.matches(of: pattern))
            guard let last = matches.last else { return [] }
            let text = String(row[last.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return matches.compactMap { match in
                guard let minutes = Double(match.1), let seconds = Double(match.2), seconds < 60 else { return nil }
                return LyricLine(time: minutes * 60 + seconds, text: text)
            }
        }.sorted { $0.time < $1.time }
    }

    static func current(in lines: [LyricLine], at position: Double) -> String? {
        lines.last(where: { $0.time <= position })?.text
    }
}

struct SpotifyPlayback: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let playing: Bool
    let artwork: URL?

    // Only query an already-running app; never launch Spotify during polling.
    static func read() throws -> SpotifyPlayback? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return nil }
        let source = """
        with timeout of 5 seconds
            tell application id "com.spotify.client"
                if player state is stopped then return {}
                set song to current track
                set coverURL to ""
                try
                    set coverURL to artwork url of song
                end try
                return {id of song, name of song, artist of song, album of song, duration of song, player position, player state is playing, coverURL}
            end tell
        end timeout
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "Spotify", code: error[NSAppleScript.errorNumber] as? Int ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "Cannot read Spotify playback."])
        }
        guard result.numberOfItems == 8,
              let id = result.atIndex(1)?.stringValue,
              let title = result.atIndex(2)?.stringValue,
              let artist = result.atIndex(3)?.stringValue,
              let album = result.atIndex(4)?.stringValue else { return nil }
        let duration = result.atIndex(5)?.doubleValue ?? 0
        let position = result.atIndex(6)?.doubleValue ?? 0
        guard duration.isFinite, duration > 0, position.isFinite, position >= 0 else { return nil }
        let artwork = result.atIndex(8)?.stringValue.flatMap(URL.init(string:))
        return SpotifyPlayback(id: id, title: title, artist: artist, album: album, duration: duration / 1000,
                               position: position, playing: result.atIndex(7)?.booleanValue ?? false,
                               artwork: artwork?.scheme == "https" ? artwork : nil)
    }
}

extension Model {
    var showingSpotify: Bool { spotifyEnabled && spotify != nil && (current == nil || current?.kind == "working") }
    var spotifyCaption: String {
        guard let spotify, !lyrics.isEmpty else { return "" }
        if !spotify.playing { return "Paused · \(spotify.title)" }
        if let line = LyricLine.current(in: lyrics, at: spotify.position) {
            return line.isEmpty ? "♪ \(spotify.title)" : line
        }
        return "♪ \(spotify.title)"
    }

    func suspendSpotify() {
        spotifyPoll?.cancel()
        spotifyPoll = nil
        lyricsTask?.cancel()
        spotify = nil
        lyrics = []
    }

    func startSpotify() {
        guard spotifyEnabled, spotifyPoll == nil else { return }
        spotifyPoll = Task { [weak self] in
            while !Task.isCancelled {
                if self?.spotifyEnabled == true {
                    do {
                        let playback = try await Task.detached(priority: .utility) { try SpotifyPlayback.read() }.value
                        guard !Task.isCancelled, let self else { return }
                        if self.spotifyEnabled {
                            if self.spotifyProblem != nil { self.spotifyProblem = nil }
                            let changed = self.spotify?.id != playback?.id
                            self.spotify = playback
                            if changed {
                                self.lyricsTask?.cancel()
                                self.lyrics = []
                                if let playback { self.loadLyrics(for: playback) }
                            }
                        }
                    } catch {
                        guard !Task.isCancelled, let self else { return }
                        self.spotify = nil
                        self.lyrics = []
                        self.lyricsTask?.cancel()
                        if (error as NSError).code == -1743 {
                            self.spotifyEnabled = false
                            self.spotifyProblem = "Allow Dyland in System Settings → Privacy & Security → Automation, then enable Spotify lyrics again."
                            return
                        }
                        self.spotifyProblem = "Spotify temporarily unavailable. Retrying automatically."
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
                let delay: Duration = self?.spotify?.playing == true ? .milliseconds(500) : .seconds(2)
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func loadLyrics(for playback: SpotifyPlayback) {
        lyricsTask = Task { [weak self] in
            var url = URLComponents(string: "https://lrclib.net/api/get")!
            url.queryItems = [URLQueryItem(name: "track_name", value: playback.title),
                              URLQueryItem(name: "artist_name", value: playback.artist),
                              URLQueryItem(name: "album_name", value: playback.album),
                              URLQueryItem(name: "duration", value: String(Int(playback.duration.rounded())))]
            var request = URLRequest(url: url.url!, timeoutInterval: 15)
            request.setValue("Dyland/0.1.0", forHTTPHeaderField: "User-Agent")
            struct Response: Decodable { let syncedLyrics: String? }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let self, self.spotifyEnabled, self.spotify?.id == playback.id else { return }
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if http.statusCode == 404 { return }
                guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
                let result = try JSONDecoder().decode(Response.self, from: data)
                self.lyrics = LyricLine.parse(result.syncedLyrics ?? "")
            } catch {
                // Lyrics are optional; failed lookups leave the lyric row hidden.
            }
        }
    }
}

@MainActor
func spotifySelfCheck() {
    let lines = LyricLine.parse("[ar:Artist]\n[00:01.20]First\n[00:03][00:05.500]Again\n[00:06.00]\n[00:99]Invalid")
    precondition(lines.map(\.time) == [1.2, 3, 5.5, 6])
    precondition(LyricLine.current(in: lines, at: 0) == nil)
    precondition(LyricLine.current(in: lines, at: 1.2) == "First")
    precondition(LyricLine.current(in: lines, at: 5.6) == "Again")
    precondition(LyricLine.current(in: lines, at: 6) == "")
    precondition(LyricLine.current(in: lines, at: 2) == "First") // Seeking backwards.
    precondition(LyricLine.parse("[ar:Artist]\nUnsynced lyrics").isEmpty)

    let defaults = UserDefaults.standard
    let keys = ["spotifyEnabled", "sessions", "sound"]
    let saved = defaults.dictionaryRepresentation()
    defer {
        for key in keys {
            if let value = saved[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    let model = Model()
    model.spotifyEnabled = true
    model.suspendSpotify() // No live Spotify or network access in self-checks.
    model.sound = false
    model.selected = ["music-test"]
    let playback = SpotifyPlayback(id: "test", title: "Song", artist: "Artist", album: "Album",
                                   duration: 120, position: 2, playing: true, artwork: nil)
    model.spotify = playback
    model.lyrics = lines
    precondition(model.showingSpotify && model.spotifyCaption == "First")
    model.lyrics = []
    precondition(model.spotifyCaption.isEmpty)
    precondition(model.islandHeight == model.islandHeaderHeight, "Missing lyrics must not reserve space")
    model.setHovered(true)
    precondition(model.islandHeight == model.islandHeaderHeight + 76)
    model.setHovered(false)
    let now = Date().timeIntervalSince1970
    let active = Notice(id: "music-working", sessionID: "music-test", kind: "working", timestamp: now)
    let question = Notice(id: "music-question", sessionID: "music-test", kind: "question", timestamp: now)
    func read(_ notices: [Notice], pending: [Notice] = []) -> BridgeRead {
        BridgeRead(snapshots: [Snapshot(version: 1, updatedAt: now, sessions: [], notices: notices, pending: pending)])
    }
    model.apply(read([active]))
    precondition(model.showingSpotify)
    model.apply(read([active], pending: [question]))
    precondition(model.current == question && !model.showingSpotify, "Recovered requests must interrupt background music")
    let done = Notice(id: "music-done", sessionID: "music-test", kind: "done", timestamp: now)
    model.apply(read([active, done], pending: [question]))
    precondition(model.current == question, "Completion must not replace an unanswered request")
    model.apply(read([active]))
    precondition(model.showingSpotify, "Resolved requests must return to music")
    model.preview()
    precondition(!model.showingSpotify)
    model.dismiss()
    precondition(model.showingSpotify)
    model.suspendSpotify()
    precondition(model.spotify == nil && model.lyrics.isEmpty && model.spotifyPoll == nil)
    model.startSpotify()
    precondition(model.spotifyPoll != nil, "Wake must restart polling without disabling Spotify")
    model.suspendSpotify()
    model.spotifyEnabled = false
    model.startSpotify()
    precondition(model.spotifyPoll == nil, "Disabled Spotify must not poll")
}
