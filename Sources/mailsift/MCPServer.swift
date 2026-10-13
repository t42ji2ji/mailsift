import Foundation
import MailCore

/// Minimal MCP server (JSON-RPC 2.0, newline-delimited, stdio) exposing the library as tools.
/// Changing mail is two steps on purpose: `preview_action` returns the exact ids and count to show the user,
/// and `perform_action` acts only on ids passed explicitly.
final class MCPServer {
    let library: MailLibrary
    init(library: MailLibrary) { self.library = library }

    static let tools: [[String: Any]] = [
        tool("search_mail", "Search the user's Apple Mail by meaning and keywords. Returns ids, dates, senders, subjects, snippets.",
             ["query": str("What to look for, in any language"), "limit": int("Max results (default 20)"),
              "account": str("Only this account email"), "sender": str("Sender address or name contains"),
              "after": str("YYYY-MM-DD"), "before": str("YYYY-MM-DD")], required: ["query"]),
        tool("read_mail", "Read one message in full (headers and plain-text body).",
             ["id": int("Message id from search_mail")], required: ["id"]),
        tool("list_senders", "Senders ranked by message count, for cleanup.",
             ["account": str("Only this account email"), "limit": int("Max rows (default 50)")], required: []),
        tool("preview_action", "Dry run: which messages an action would touch. Show the count to the user before perform_action.",
             ["action": str("trash | archive | markRead | markUnread | flag | unflag"),
              "ids": ["type": "array", "items": ["type": "integer"], "description": "Message ids"],
              "sender": str("Instead of ids: every indexed message from this exact address (trash only)"),
              "account": str("Limit sender selection to this account")], required: ["action"]),
        tool("perform_action", "Apply an action to exactly these ids. Trash moves to the mailbox's Trash (recoverable for 30 days in Gmail). Only call after the user confirmed the preview.",
             ["action": str("trash | archive | markRead | markUnread | flag | unflag"),
              "ids": ["type": "array", "items": ["type": "integer"], "description": "Message ids"]], required: ["action", "ids"]),
        tool("index_status", "How much mail is indexed (keyword and semantic).", [:], required: []),
    ]

    static func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": props, "required": required]]
    }
    static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"]
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue }  // notifications need no reply
            switch method {
            case "initialize":
                reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                           "capabilities": ["tools": [:]],
                           "serverInfo": ["name": "mailsift", "version": "0.1.0"]])
            case "tools/list":
                reply(id, ["tools": Self.tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let input = params["arguments"] as? [String: Any] ?? [:]
                do {
                    reply(id, ["content": [["type": "text", "text": try await call(name, input)]]])
                } catch {
                    reply(id, ["content": [["type": "text", "text": "error: \(error.localizedDescription)"]], "isError": true])
                }
            case "ping":
                reply(id, [:])
            default:
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "unknown method \(method)"]])
            }
        }
    }

    func call(_ name: String, _ a: [String: Any]) async throws -> String {
        switch name {
        case "search_mail":
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let filter = SearchFilter(account: a["account"] as? String, sender: a["sender"] as? String,
                                      after: (a["after"] as? String).flatMap(f.date), before: (a["before"] as? String).flatMap(f.date))
            let hits = try await library.search(a["query"] as? String ?? "", filter: filter, limit: a["limit"] as? Int ?? 20)
            return encode(hits)
        case "read_mail":
            var m = try library.message(id: Int64(a["id"] as? Int ?? -1))
            m.html = nil
            return encode(m)
        case "list_senders":
            return encode(library.senders(account: a["account"] as? String, limit: a["limit"] as? Int ?? 50))
        case "preview_action":
            let action = try parseAction(a["action"])
            var ids = (a["ids"] as? [Int] ?? []).map(Int64.init)
            if let sender = a["sender"] as? String {
                guard action == .trash else { throw MailSourceError.other("sender selection is only for trash") }
                ids = library.messages(fromSender: sender, account: a["account"] as? String).map(\.id)
            }
            return encode(Preview(action: action, count: ids.count, ids: ids))
        case "perform_action":
            let ids = (a["ids"] as? [Int] ?? []).map(Int64.init)
            guard !ids.isEmpty else { throw MailSourceError.other("ids is empty") }
            return encode(try await library.perform(try parseAction(a["action"]), ids: ids))
        case "index_status":
            return encode(library.status())
        default:
            throw MailSourceError.other("unknown tool \(name)")
        }
    }

    struct Preview: Encodable {
        let action: MailAction
        let count: Int
        let ids: [Int64]
    }

    func parseAction(_ v: Any?) throws -> MailAction {
        guard let s = v as? String, let a = MailAction(rawValue: s) else {
            throw MailSourceError.other("action must be one of \(MailAction.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return a
    }

    func encode<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return String(data: (try? e.encode(value)) ?? Data(), encoding: .utf8) ?? ""
    }

    func reply(_ id: Any?, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id!, "result": result])
    }

    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
