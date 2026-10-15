import Foundation
import MailCore

/// Minimal MCP server (JSON-RPC 2.0, newline-delimited, stdio) exposing the library as tools.
/// Changing mail is two steps on purpose: `preview_action` returns the exact ids and count to show the user,
/// and `perform_action` acts only on ids passed explicitly. The in-app agent gets `propose_action` instead, which
/// changes nothing: the app shows the proposal and performs it after the user confirms.
final class MCPServer {
    let library: MailLibrary
    /// Loads this process's own model; started only when the app cannot answer a search.
    let loadModel: () -> Task<Void, Never>
    private lazy var modelReady = loadModel()
    init(library: MailLibrary, loadModel: @escaping () -> Task<Void, Never>) {
        self.library = library
        self.loadModel = loadModel
    }

    static let tools: [[String: Any]] = [
        tool("search_mail", "Search the user's Apple Mail by meaning and keywords. Rows as in list_recent.",
             ["query": str("What to look for, in any language"), "limit": int("Max results (default 20)"),
              "account": str("Only this account email"), "sender": str("Sender address or name contains"),
              "after": str("YYYY-MM-DD"), "before": str("YYYY-MM-DD")], required: ["query"]),
        tool("list_recent", """
            Newest messages first, filtered. Covers the newest \(recentWindow) messages of the mailbox. \(rowHelp)
            """,
             ["limit": int("Max results (default 50)"), "after": str("YYYY-MM-DD, inclusive (local time)"),
              "before": str("YYYY-MM-DD, exclusive (local time)"), "account": str("Only this account email"),
              "mailbox": str("inbox (default) | flagged | archive | all (inbox and archive, including mail the user sent)"),
              "unread": bool("true: only unread; false: only read"),
              "list": bool("true: only mailing-list mail (newsletters, notifications); false: none of it"),
              "known": bool("true: only senders the user has written to; false: only senders they never wrote to"),
              "from_me": bool("true: only mail the user sent; false: leave it out"),
              "awaiting": bool("true: only conversations whose latest message is the user's (waiting for an answer)"),
              "replied": bool("true: only messages the user answered later in the conversation; false: unanswered")],
             required: []),
        tool("read_mail", "Read one message in full (headers and plain-text body).",
             ["id": int("Message id from search_mail")], required: ["id"]),
        tool("read_thread", "Read the whole conversation a message belongs to, oldest first (bodies cut to 1500 characters).",
             ["id": int("Any message id in the conversation")], required: ["id"]),
        tool("list_senders", "Senders ranked by message count, with unread count and whether the user has ever written to them (known). For cleanup.",
             ["account": str("Only this account email"), "after": str("YYYY-MM-DD: count only mail since then"),
              "known": bool("true: only senders the user has written to; false: only the others"),
              "limit": int("Max rows (default 50)")], required: []),
        tool("preview_action", "Dry run: which messages an action would touch. Show the count to the user before perform_action.",
             ["action": str("trash | archive | markRead | markUnread | flag | unflag | restore | junk"),
              "ids": ["type": "array", "items": ["type": "integer"], "description": "Message ids"],
              "sender": str("Instead of ids: every indexed message from this exact address (trash only)"),
              "account": str("Limit sender selection to this account")], required: ["action"]),
        tool("perform_action", "Apply an action to exactly these ids. Trash moves to the mailbox's Trash (recoverable for 30 days in Gmail). Only call after the user confirmed the preview.",
             ["action": str("trash | archive | markRead | markUnread | flag | unflag | restore | junk"),
              "ids": ["type": "array", "items": ["type": "integer"], "description": "Message ids"]], required: ["action", "ids"]),
        tool("propose_action", """
            Propose an action for the user to confirm in the app. Does not change mail. The app lists every message \
            with a checkbox; the user unticks any they want to keep out. Give per-message reasons in items when the \
            messages were judged one by one.
            """,
             ["action": str("trash | archive | markRead | markUnread | flag | unflag | restore | junk"),
              "ids": ["type": "array", "items": ["type": "integer"], "description": "Message ids (or use items)"],
              "items": ["type": "array", "description": "Instead of ids: each message with its own reason",
                        "items": ["type": "object", "required": ["id"], "properties": [
                            "id": int("Message id"), "reason": str("A few words: why this one"),
                            "checked": bool("false when unsure: listed but unticked (default true)")]]],
              "reason": str("One short sentence: why these messages")], required: ["action", "reason"]),
        tool("draft_reply", "Show the user a reply draft for one message. Does not send: the user edits it and opens it in Mail.",
             ["id": int("Message id to reply to"), "body": str("The reply text only: no subject, no greeting quote of the original"),
              "reply_all": ["type": "boolean", "description": "Reply to all recipients (default false)"]], required: ["id", "body"]),
        tool("index_status", "How much mail is indexed (keyword and semantic).", [:], required: []),
    ]

    static let recentWindow = 2000
    /// Set by MailSift's in-app assistant: it may only propose changes, so the acting tools are hidden and refused.
    static let agentMode = ProcessInfo.processInfo.environment["MAILSIFT_AGENT"] == "1"
    static let agentHidden: Set<String> = ["preview_action", "perform_action"]
    static var listed: [[String: Any]] {
        agentMode ? tools.filter { !agentHidden.contains($0["name"] as? String ?? "") } : tools
    }

    static func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": props, "required": required]]
    }
    static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }

    static let rowHelp = """
        Each row: id, date, sender, subject, snippet, account, and flags present only when true: unread, isFlagged, \
        archived (not in the inbox), list (mailing list: newsletter, notification), fromMe, known (the user has \
        written to this sender), replied (the user answered later in the conversation), awaiting (the conversation's \
        latest message is the user's); thread = message count when the conversation has more than one.
        """

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
                reply(id, ["tools": Self.listed])
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
        if Self.agentMode, Self.agentHidden.contains(name) { throw MailSourceError.other("unknown tool \(name)") }
        switch name {
        case "search_mail":
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let filter = SearchFilter(account: a["account"] as? String, sender: a["sender"] as? String,
                                      after: (a["after"] as? String).flatMap(f.date), before: (a["before"] as? String).flatMap(f.date))
            let query = a["query"] as? String ?? "", limit = a["limit"] as? Int ?? 20
            if let hits = SearchService.search(query, filter: filter, limit: limit) { return encode(rows(hits)) }
            await modelReady.value
            return encode(rows(try await library.search(query, filter: filter, limit: limit)))
        case "list_recent":
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let after = (a["after"] as? String).flatMap(f.date), before = (a["before"] as? String).flatMap(f.date)
            let account = a["account"] as? String
            let box = a["mailbox"] as? String ?? "inbox"
            let window = box == "all"
                ? (library.recent(.inbox, limit: Self.recentWindow) + library.recent(.archive, limit: Self.recentWindow))
                    .sorted { $0.meta.date > $1.meta.date }.prefix(Self.recentWindow).map { $0 }
                : library.recent(BrowseBox(rawValue: box) ?? .inbox, limit: Self.recentWindow)
            let unread = a["unread"] as? Bool
            let hits = window.filter { hit in
                let m = hit.meta
                return after.map { m.date >= $0 } ?? true && before.map { m.date < $0 } ?? true
                    && account.map { m.mailbox.account.caseInsensitiveCompare($0) == .orderedSame } ?? true
                    && unread.map { m.isRead != $0 } ?? true
            }
            let filters = ["list", "known", "from_me", "awaiting", "replied"].filter { a[$0] is Bool }
            var result = rows(filters.isEmpty ? Array(hits.prefix(a["limit"] as? Int ?? 50)) : hits)
            for key in filters {
                let want = a[key] as! Bool
                result = result.filter { row in
                    let value = switch key {
                    case "list": row.list
                    case "known": row.known
                    case "from_me": row.fromMe
                    case "awaiting": row.awaiting
                    default: row.replied
                    }
                    return (value ?? false) == want
                }
            }
            return encode(Array(result.prefix(a["limit"] as? Int ?? 50)))
        case "read_mail":
            var m = try library.message(id: Int64(a["id"] as? Int ?? -1))
            m.html = nil
            return encode(m)
        case "read_thread":
            return encode(try library.thread(Int64(a["id"] as? Int ?? -1)).map(ThreadMessage.init))
        case "list_senders":
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let known = library.correspondents()
            let wantKnown = a["known"] as? Bool
            let limit = a["limit"] as? Int ?? 50
            // Filtering by known happens after ranking, so ask for more rows.
            let stats = library.senders(account: a["account"] as? String, after: (a["after"] as? String).flatMap(f.date),
                                        limit: wantKnown == nil ? limit : limit * 10)
            let rows = stats.map { SenderRow($0, known: known.contains($0.address.lowercased())) }
                .filter { row in wantKnown.map { row.known == $0 } ?? true }
            return encode(Array(rows.prefix(limit)))
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
        case "propose_action":
            _ = try parseAction(a["action"])
            guard !(a["ids"] as? [Int] ?? []).isEmpty || !(a["items"] as? [[String: Any]] ?? []).isEmpty else {
                throw MailSourceError.other("ids or items is required")
            }
            return "Proposal shown to the user; they will confirm in the app."
        case "draft_reply":
            guard a["id"] is Int, !(a["body"] as? String ?? "").isEmpty else { throw MailSourceError.other("id and body are required") }
            return "Draft shown to the user; they can edit it and open it in Mail."
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

    /// A message for the agent. Flags are left out when false to keep long lists short.
    struct Row: Encodable {
        let id: Int64
        let date: Date
        let sender: String
        let subject: String
        let snippet: String
        let account: String
        var unread, isFlagged, archived, list, fromMe, known, replied, awaiting: Bool?
        var thread: Int?

        init(_ hit: SearchHit, _ t: MailTraits?) {
            let m = hit.meta
            id = m.id
            date = m.date
            sender = Self.sender(m)
            subject = m.subject
            snippet = hit.snippet
            account = m.mailbox.account
            func on(_ b: Bool) -> Bool? { b ? true : nil }
            unread = on(!m.isRead)
            isFlagged = on(m.isFlagged)
            archived = on(!m.inInbox)
            list = on(t?.isList ?? false)
            fromMe = on(t?.fromMe ?? false)
            known = on(t?.knownSender ?? false)
            replied = on(t?.repliedByMe ?? false)
            awaiting = on(t?.lastFromMe ?? false)
            thread = (t?.threadCount ?? 1) > 1 ? t?.threadCount : nil
        }

        static func sender(_ m: MessageMeta) -> String {
            m.senderName.isEmpty ? m.senderAddress : "\(m.senderName) <\(m.senderAddress)>"
        }
    }

    func rows(_ hits: [SearchHit]) -> [Row] {
        let traits = library.traits(hits.map(\.meta))
        return hits.map { Row($0, traits[$0.id]) }
    }

    struct ThreadMessage: Encodable {
        let id: Int64
        let date: Date
        let sender: String
        let subject: String
        let body: String

        init(_ m: ParsedMessage) {
            id = m.meta.id
            date = m.meta.date
            sender = Row.sender(m.meta)
            subject = m.meta.subject
            body = String(m.bodyText.prefix(1500))
        }
    }

    struct SenderRow: Encodable {
        let address: String
        let name: String
        let account: String
        let count: Int
        let unread: Int
        let latest: Date
        let known: Bool

        init(_ s: SenderStat, known: Bool) {
            address = s.address; name = s.name; account = s.account; count = s.count; unread = s.unread
            latest = s.latest; self.known = known
        }
    }

    func parseAction(_ v: Any?) throws -> MailAction {
        guard let s = v as? String, let a = MailAction(rawValue: s), a != .deletePermanently else {
            throw MailSourceError.other("action must be one of \(MailAction.allCases.filter { $0 != .deletePermanently }.map(\.rawValue).joined(separator: ", "))")
        }
        return a
    }

    func encode<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Local offset rather than UTC, so "today" in the user's time zone reads correctly.
        let dates = ISO8601DateFormatter()
        dates.timeZone = .current
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(dates.string(from: date))
        }
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
