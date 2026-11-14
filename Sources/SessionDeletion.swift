import Foundation

// Use CLI discovery/authentication, never edit OpenCode storage or Dyland bridge files.
enum SessionDeletion {
    private struct Info: Decodable {
        let id: String
        let parentID: String?
    }
    private struct Page: Decodable {
        let data: [Info]
        let cursor: Cursor
        struct Cursor: Decodable { let next: String? }
    }
    private struct Active: Decodable {
        let data: [String: State]
        struct State: Decodable { let type: String }
    }

    static func remove(_ session: Session) async throws -> Set<String> {
        try await Task.detached(priority: .userInitiated) {
            let executable = try TerminalRouter.findOpenCode()
            return try perform(session) { arguments in
                try TerminalRouter.run(executable, ["api"] + arguments, directory: session.directory)
            }
        }.value
    }

    static func perform(_ session: Session, request: ([String]) throws -> String) throws -> Set<String> {
        func fail(_ message: String) -> TerminalRouter.Failure { .init(message: message) }
        guard TerminalRouter.validSessionID(session.id), session.directory.hasPrefix("/"), !session.directory.contains("\0") else {
            throw fail("Invalid session ID or directory. Nothing was deleted.")
        }
        func validate() throws {
            let response = try request(["session.get", "--param", "sessionID=\(session.id)"])
            guard TerminalRouter.validResponse(response, for: session),
                  let envelope = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                  let info = envelope["data"] as? [String: Any], info["parentID"] == nil else {
                throw fail("Session no longer matches this root session and directory. Refresh OpenCode and try again.")
            }
        }
        try validate()
        var ids: Set<String> = [session.id]
        var queue = [session.id]
        var index = 0
        while index < queue.count {
            let parent = queue[index]
            index += 1
            var cursor: String?
            var cursors = Set<String>()
            repeat {
                var arguments = ["session.list", "--param", "parentID=\(parent)", "--param", "limit=200"]
                if let cursor { arguments += ["--param", "cursor=\(cursor)"] }
                let page = try JSONDecoder().decode(Page.self, from: Data(request(arguments).utf8))
                for child in page.data {
                    guard TerminalRouter.validSessionID(child.id), child.parentID == parent,
                          ids.insert(child.id).inserted, ids.count <= 1_000 else {
                        throw fail("Cannot safely verify child sessions. Nothing was deleted.")
                    }
                    queue.append(child.id)
                }
                cursor = page.cursor.next
                if let cursor {
                    guard !page.data.isEmpty, cursors.insert(cursor).inserted, cursors.count <= 1_000 else {
                        throw fail("Cannot safely read all child sessions. Nothing was deleted.")
                    }
                }
            } while cursor != nil
        }
        for id in queue {
            for operation in ["session.form.list", "session.permission.list"] {
                let response = try request([operation, "--param", "sessionID=\(id)"])
                guard let envelope = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                      let pending = envelope["data"] as? [Any] else {
                    throw fail("Cannot verify pending requests. Nothing was deleted.")
                }
                guard pending.isEmpty else {
                    throw fail("This session or a child session has a pending request. Resolve it in OpenCode, then try again.")
                }
            }
        }
        try validate()
        let active = try JSONDecoder().decode(Active.self, from: Data(request(["session.active"]).utf8))
        guard active.data.values.allSatisfy({ $0.type == "running" }) else {
            throw fail("Cannot verify session activity. Nothing was deleted.")
        }
        guard ids.isDisjoint(with: active.data.keys) else {
            throw fail("This session or a child session is working. Wait for it to finish, then try again.")
        }
        // ponytail: preflight is not atomic; use a server-side idle-only delete if OpenCode adds one.
        _ = try request(["session.remove", "--param", "sessionID=\(session.id)"])
        return ids
    }

    static func selfCheck() throws {
        let session = Session(id: "ses_root", title: "Test", directory: "/test", updatedAt: 0)
        func check(busy: String? = nil, pending: String? = nil, pendingOperation: String = "session.form.list", mismatch: Bool = false, malformed: Bool = false, deleteFails: Bool = false) throws -> (Set<String>, Int) {
            var deletes = 0
            do {
                let ids = try perform(session) { args in
                    switch args.first {
                    case "session.get":
                        return mismatch ? #"{"data":{"id":"ses_root","location":{"directory":"/other"}}}"# : #"{"data":{"id":"ses_root","location":{"directory":"/test"}}}"#
                    case "session.list":
                        if malformed { return #"{"data":[]}"# }
                        if args.contains("parentID=ses_root") {
                            if args.contains("cursor=next") { return #"{"data":[{"id":"ses_second","parentID":"ses_root"}],"cursor":{"next":null}}"# }
                            return #"{"data":[{"id":"ses_child","parentID":"ses_root"}],"cursor":{"next":"next"}}"#
                        }
                        if args.contains("parentID=ses_child") { return #"{"data":[{"id":"ses_grandchild","parentID":"ses_child"}],"cursor":{"next":null}}"# }
                        return #"{"data":[],"cursor":{"next":null}}"#
                    case "session.form.list", "session.permission.list":
                        if let pending, args.first == pendingOperation, args.contains("sessionID=\(pending)") {
                            return #"{"data":[{"id":"pending"}]}"#
                        }
                        return #"{"data":[]}"#
                    case "session.active":
                        return busy.map { "{\"data\":{\"\($0)\":{\"type\":\"running\"}}}" } ?? #"{"data":{}}"#
                    case "session.remove":
                        deletes += 1
                        if deleteFails { throw TerminalRouter.Failure(message: "Test deletion failure") }
                        return ""
                    default: preconditionFailure("Unexpected API operation")
                    }
                }
                return (ids, deletes)
            } catch {
                precondition(deletes == (deleteFails ? 1 : 0), "Failed preflight must never delete")
                throw error
            }
        }
        let (ids, deletes) = try check()
        precondition(ids == ["ses_root", "ses_child", "ses_second", "ses_grandchild"] && deletes == 1)
        _ = try check(busy: "ses_unrelated")
        for busy in ["ses_root", "ses_child", "ses_grandchild"] {
            do { _ = try check(busy: busy); preconditionFailure("Active sessions must be protected") }
            catch is TerminalRouter.Failure {}
        }
        for id in ["ses_root", "ses_child", "ses_grandchild"] {
            for operation in ["session.form.list", "session.permission.list"] {
                do { _ = try check(pending: id, pendingOperation: operation); preconditionFailure("Pending requests must be protected") }
                catch is TerminalRouter.Failure {}
            }
        }
        do { _ = try check(mismatch: true); preconditionFailure("Wrong directory must fail") }
        catch is TerminalRouter.Failure {}
        do { _ = try check(malformed: true); preconditionFailure("Incomplete snapshots must fail") }
        catch is DecodingError {}
        do { _ = try check(deleteFails: true); preconditionFailure("Delete errors must propagate") }
        catch is TerminalRouter.Failure {}
        print("SessionDeletion self-check passed")
    }
}
