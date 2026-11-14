// Compile with Sources/*.swift except App.swift, then run:
// DYLAND_DELETE_CHECK=/path/to/compiled-check npm run test:e2e --prefix plugin
import Foundation

@main struct SessionDeletionCheck {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["DYLAND_E2E_SERVER"], let url = URL(string: server), url.host == "127.0.0.1",
              env["OPENCODE_PASSWORD"] != nil, let directory = env["DYLAND_E2E_DIRECTORY"] else {
            fatalError("Run only through the isolated plugin E2E server")
        }
        let executable = try TerminalRouter.findOpenCode()
        func api(_ args: [String]) throws -> String {
            try TerminalRouter.run(executable, ["api", "--server", server] + args, directory: directory)
        }
        func create(parent: String? = nil) throws -> String {
            var body: [String: Any] = ["title": "Dyland Swift deletion E2E", "location": ["directory": directory]]
            if let parent { body["parentID"] = parent }
            let response = try api(["session.create", "--data", String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self)])
            let envelope = try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]
            return (envelope["data"] as! [String: Any])["id"] as! String
        }
        let root = try create()
        defer { _ = try? api(["session.remove", "--param", "sessionID=\(root)"]) }
        let child = try create(parent: root)
        let grandchild = try create(parent: child)
        let session = Session(id: root, title: "Test", directory: directory, updatedAt: 0)
        let formResponse = try api(["post", "/api/session/\(child)/form", "--data", #"{"title":"Deletion protection E2E","fields":[{"type":"boolean","key":"confirm","required":true}]}"#])
        let formEnvelope = try JSONSerialization.jsonObject(with: Data(formResponse.utf8)) as! [String: Any]
        let formID = (formEnvelope["data"] as! [String: Any])["id"] as! String
        do {
            _ = try SessionDeletion.perform(session, request: api)
            preconditionFailure("Pending child form must block deletion")
        } catch let error as TerminalRouter.Failure {
            precondition(error.message.contains("pending request"))
        }
        _ = try api(["session.get", "--param", "sessionID=\(root)"])
        _ = try api(["post", "/api/session/\(child)/form/\(formID)/reply", "--data", #"{"answer":{"confirm":true}}"#])
        let deleted = try SessionDeletion.perform(session, request: api)
        precondition(deleted == [root, child, grandchild])
        for id in deleted {
            do {
                _ = try api(["session.get", "--param", "sessionID=\(id)"])
                preconditionFailure("Deleted session must not exist")
            } catch is TerminalRouter.Failure {}
        }
        print("Swift deletion E2E passed: CLI authentication, root validation, child traversal, active preflight, cascading delete")
    }
}
