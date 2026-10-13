import Foundation

/// One line of `claude -p --output-format stream-json --verbose --include-partial-messages`, reduced to what the
/// agent panel uses. Foundation only, so it can be exercised outside the app.
enum AgentEvent: Equatable, Sendable {
    struct ToolUse: Equatable, Sendable {
        var id: String
        var name: String
        /// Input as compact JSON; decode with `AgentStream.object`.
        var input: String
    }

    enum Block: Equatable, Sendable {
        case text(String)
        case toolUse(ToolUse)
    }

    case initialized(sessionID: String, mcpStatus: String?)
    /// Streamed text for content block `index` of message `messageID`.
    case textDelta(messageID: String, index: Int, text: String)
    /// A complete assistant message (authoritative for the blocks it carries).
    case assistant(messageID: String, blocks: [Block])
    case toolResult(toolUseID: String, isError: Bool, text: String)
    case result(sessionID: String?, isError: Bool, subtype: String, text: String, cost: Double?)
    case ignored
}

enum AgentStream {
    static let mcpServer = "mailsift"

    static func parse(_ line: String) -> AgentEvent {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        switch obj["type"] as? String {
        case "system":
            guard obj["subtype"] as? String == "init", let session = obj["session_id"] as? String else { return .ignored }
            let servers = obj["mcp_servers"] as? [[String: Any]] ?? []
            let status = servers.first { $0["name"] as? String == mcpServer }?["status"] as? String
            return .initialized(sessionID: session, mcpStatus: status)

        case "stream_event":
            guard let event = obj["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, let index = event["index"] as? Int,
                  let messageID = obj["api_message_id"] as? String else { return .ignored }
            return .textDelta(messageID: messageID, index: index, text: text)

        case "assistant":
            guard let message = obj["message"] as? [String: Any], let id = message["id"] as? String else { return .ignored }
            let blocks: [AgentEvent.Block] = (message["content"] as? [[String: Any]] ?? []).compactMap { block in
                switch block["type"] as? String {
                case "text":
                    return (block["text"] as? String).map { .text($0) }
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                    return .toolUse(.init(id: id, name: name, input: json(block["input"] ?? [String: Any]())))
                default:
                    return nil
                }
            }
            return .assistant(messageID: id, blocks: blocks)

        case "user":
            // Tool results come back as a user message; one per line in practice.
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]],
                  let block = content.first(where: { $0["type"] as? String == "tool_result" }),
                  let id = block["tool_use_id"] as? String else { return .ignored }
            return .toolResult(toolUseID: id, isError: block["is_error"] as? Bool ?? false, text: text(block["content"]))

        case "result":
            return .result(sessionID: obj["session_id"] as? String, isError: obj["is_error"] as? Bool ?? false,
                           subtype: obj["subtype"] as? String ?? "", text: obj["result"] as? String ?? "",
                           cost: obj["total_cost_usd"] as? Double)

        default:
            return .ignored
        }
    }

    /// Tool result content is a string or a list of `{type: text, text}` parts.
    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        let parts = content as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// Splits a byte stream into lines; a tool result can be one long line spread over many reads.
    struct LineBuffer {
        private var pending = Data()

        mutating func append(_ data: Data) -> [String] {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }

        mutating func finish() -> [String] {
            defer { pending = Data() }
            return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
        }
    }
}

/// Sender and subject for rendering `[[id]]` references.
struct MailRef: Equatable, Sendable {
    var id: Int64
    var sender: String
    var subject: String
}

extension AgentStream {
    /// Messages named in a mailsift tool result: search_mail hits, list_recent rows, read_mail.
    static func refs(inToolResult text: String) -> [MailRef] {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return [] }
        let rows = value as? [[String: Any]] ?? [value as? [String: Any]].compactMap { $0 }
        return rows.compactMap { row in
            if let meta = row["meta"] as? [String: Any], let id = (meta["id"] as? NSNumber)?.int64Value {
                let name = meta["senderName"] as? String ?? ""
                return MailRef(id: id, sender: name.isEmpty ? meta["senderAddress"] as? String ?? "" : name,
                               subject: meta["subject"] as? String ?? "")
            }
            if let id = (row["id"] as? NSNumber)?.int64Value, let sender = row["sender"] as? String {
                // "Name <address>" → Name
                let name = sender.components(separatedBy: " <").first ?? sender
                return MailRef(id: id, sender: name, subject: row["subject"] as? String ?? "")
            }
            return nil
        }
    }

    /// Message ids written as `[[123]]`.
    static let refPattern = #/\[\[(\d+)\]\]/#
}
