import Foundation

/// A row of Envelope Index `mailboxes`, decoded.
struct AppleMailbox: Sendable, Hashable {
    var id: Int64
    var accountUUID: String       // URL host; equals AppleScript `id` of the account
    var scheme: String            // imap, ews, local, …
    var path: String              // decoded, e.g. "[Gmail]/All Mail" — also the AppleScript mailbox name
    var role: MailboxRole

    var isGmailSystem: Bool { AppleMailbox.gmailPrefixes.contains { path.hasPrefix($0) } }

    static let gmailPrefixes = ["[Gmail]/", "[Google Mail]/"]

    /// Parses `imap://<UUID>/%5BGmail%5D/All%20Mail`. Returns nil for URLs without a host.
    init?(id: Int64, url: String) {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let scheme = String(url[..<schemeEnd.lowerBound])
        let rest = url[schemeEnd.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = String(rest[..<slash])
        guard !host.isEmpty else { return nil }
        let rawPath = slash < rest.endIndex ? String(rest[rest.index(after: slash)...]) : ""
        let path = rawPath.removingPercentEncoding ?? rawPath
        self.id = id
        self.accountUUID = host
        self.scheme = scheme
        self.path = path
        self.role = MailboxRoles.role(forPath: path)
    }
}

enum MailboxRoles {
    // Lowercased leaf names (and Gmail system-folder names in the locales we have seen).
    private static let table: [(MailboxRole, Set<String>)] = [
        (.inbox, ["inbox", "收件匣", "收件箱"]),
        (.allMail, ["all mail", "全部郵件", "所有郵件", "所有邮件", "全部邮件"]),
        (.sent, ["sent mail", "sent", "sent messages", "sent items", "寄件備份", "已傳送郵件", "已傳送", "已发邮件",
                 "已發送郵件", "已发送邮件", "已发送", "寄件匣"]),
        (.drafts, ["drafts", "draft", "草稿", "草稿匣", "草稿箱"]),
        (.trash, ["trash", "bin", "deleted messages", "deleted items", "垃圾桶", "已刪除郵件", "已删除邮件",
                  "已刪除的郵件", "废纸篓", "廢紙簍", "已删除"]),
        (.spam, ["spam", "junk", "junk e-mail", "junk email", "bulk mail", "垃圾郵件", "垃圾邮件"]),
        (.archive, ["archive", "archives", "封存", "已封存", "归档", "歸檔", "存档"]),
        (.flagged, ["starred", "flagged", "已加星號", "已加星标", "已標記", "星號郵件"]),
        (.important, ["important", "重要郵件", "重要邮件"]),
    ]

    static func role(forPath path: String) -> MailboxRole {
        let isGmail = AppleMailbox.gmailPrefixes.contains { path.hasPrefix($0) }
        // Only the Gmail system folders and top-level folders carry a role; "Work/Archive" is a user folder.
        guard isGmail || !path.contains("/") else { return .other }
        let leaf = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        // A top-level user label named like a system folder gets that role too; only trash/spam/drafts hide mail.
        for (role, names) in table where names.contains(leaf) { return role }
        return .other
    }

    /// Mailboxes whose messages are not searchable.
    static func isExcluded(_ mb: AppleMailbox) -> Bool {
        switch mb.role {
        case .trash, .spam, .drafts: return true
        default: return mb.path.caseInsensitiveCompare("Outbox") == .orderedSame
        }
    }
}

/// Maps Mail account UUIDs (mailbox URL host) to the account's email address.
enum AppleAccounts {
    /// Reads ~/Library/Accounts/Accounts4.sqlite: Mail's account is a child row (empty ZUSERNAME) whose parent
    /// carries the address. Missing file or rows just yield an empty map; callers fall back to the UUID.
    static func emailsByUUID(accountsDB: String) -> [String: String] {
        guard FileManager.default.fileExists(atPath: accountsDB),
              let db = try? ReadOnlySQLite(path: accountsDB) else { return [:] }
        var out: [String: String] = [:]
        try? db.query("""
            select a.ZIDENTIFIER, a.ZUSERNAME, p.ZUSERNAME from ZACCOUNT a
            left join ZACCOUNT p on a.ZPARENTACCOUNT = p.Z_PK
            """) { row in
            guard let uuid = row.text(0) else { return }
            let candidates = [row.text(1), row.text(2)].compactMap { $0 }.filter { $0.contains("@") }
            if let email = candidates.first { out[uuid] = email.lowercased() }
        }
        return out
    }
}
