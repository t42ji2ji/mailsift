import Foundation

/// Builds the AppleScript that acts on messages in Mail.app. Pure functions; `MailScriptRunner` executes.
///
/// Messages are addressed as `«class mssg» id N of <mailbox>`: a direct lookup by Envelope Index ROWID that costs
/// ~20 ms per message. (`whose id is in {…}` is rejected by Mail and OR-chained `whose` clauses scan the mailbox once
/// per clause.) Each id runs in its own `try`, so a missing message fails alone; the script returns one line
/// "<id>\t<error>" per failure.
enum MailScript {
    struct MailboxSpec: Hashable {
        var accountUUID: String?   // nil for "On My Mac" mailboxes
        var path: String

        var reference: String {
            let mb = "mailbox \"\(escape(path))\""
            guard let a = accountUUID else { return mb }
            return mb + " of account id \"\(escape(a))\""
        }
    }

    /// The statement applied to one message reference `m` (an expression, not a variable).
    static func statement(_ action: MailAction, message m: String, target: MailboxSpec?) -> String {
        switch action {
        case .trash: return "delete \(m)"
        case .archive, .restore: return "move \(m) to \(target?.reference ?? "missing value")"
        case .junk: return "set junk mail status of \(m) to true\n\t\t\tmove \(m) to \(target?.reference ?? "missing value")"
        case .markRead: return "set read status of \(m) to true"
        case .markUnread: return "set read status of \(m) to false"
        case .flag: return "set flagged status of \(m) to true"
        case .unflag: return "set flagged status of \(m) to false"
        }
    }

    /// One script acting on `ids` that live in (or, for Gmail archive, carry the label of) `source`.
    static func script(_ action: MailAction, ids: [Int64], source: MailboxSpec, target: MailboxSpec? = nil) -> String {
        let list = ids.map(String.init).joined(separator: ", ")
        let stmt = statement(action, message: "(«class mssg» id (contents of i) of mb)", target: target)
        return """
        tell application "Mail"
        \tset mb to \(source.reference)
        \tset out to ""
        \trepeat with i in {\(list)}
        \t\ttry
        \t\t\t\(stmt)
        \t\ton error errMsg number errNum
        \t\t\tset out to out & ((contents of i) as text) & tab & (errNum as text) & " " & errMsg & linefeed
        \t\tend try
        \tend repeat
        \treturn out
        end tell
        """
    }

    /// Saves one attachment of message `id` to `path`; Mail fetches it from the server first if needed.
    /// The attachment is the first whose name is one of `names`.
    static func saveAttachment(id: Int64, in source: MailboxSpec, names: [String], to path: String) -> String {
        let list = names.map { "\"\(escape($0))\"" }.joined(separator: ", ")
        return """
        tell application "Mail"
        \tset m to «class mssg» id \(id) of \(source.reference)
        \trepeat with a in mail attachments of m
        \t\tif {name of a} is in {\(list)} then
        \t\t\tsave a in POSIX file "\(escape(path))"
        \t\t\treturn "ok"
        \t\tend if
        \tend repeat
        \terror "No attachment named " & item 1 of {\(list)}
        end tell
        """
    }

    /// Opens a reply or forward window (visible, not sent). `body` goes above the quoted original.
    static func compose(_ kind: ComposeKind, id: Int64, source: MailboxSpec, body: String?) -> String {
        let make = switch kind {
        case .reply: "reply m with opening window"
        case .replyAll: "reply m with opening window and reply to all"
        case .forward: "forward m with opening window"
        }
        var lines = ["tell application \"Mail\"", "\tset m to «class mssg» id \(id) of \(source.reference)", "\tset r to \(make)"]
        if let body, !body.isEmpty {
            let literal = body.components(separatedBy: "\n").map { "\"" + escape($0) + "\"" }.joined(separator: " & return & ")
            lines.append("\tdelay 0.3")
            lines.append("\tset content of r to \(literal) & return & return & (content of r)")
        }
        lines += ["\tactivate", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// Parses the script result into failures keyed by id.
    static func failures(fromOutput output: String) -> [Int64: String] {
        var out: [Int64: String] = [:]
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if let id = Int64(parts[0].trimmingCharacters(in: .whitespaces)) {
                out[id] = parts.count > 1 ? String(parts[1]) : "failed"
            }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Runs AppleScript source through /usr/bin/osascript.
enum MailScriptRunner {
    static func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try runSync(source)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func runSync(_ source: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        do { try p.run() } catch {
            throw MailSourceError.other("Cannot run osascript: \(error.localizedDescription)")
        }
        stdin.fileHandleForWriting.write(Data(source.utf8))
        try? stdin.fileHandleForWriting.close()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus == 0 { return out }
        if err.contains("-1743") || err.contains("-1744") { throw MailSourceError.automationDenied }
        throw MailSourceError.other("Mail script failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}
