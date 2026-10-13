import Foundation

// Shared types between the mail source (reading / acting on mail), the library (index + search),
// and the front ends (CLI, MCP, SwiftUI app). Front ends talk only to `MailLibrary`.

public enum MailboxRole: String, Codable, Sendable {
    case allMail, inbox, sent, drafts, trash, spam, archive, flagged, important, other
}

public struct MailboxRef: Codable, Sendable, Hashable {
    public var id: Int64          // source-specific mailbox id (Apple Mail: Envelope Index mailboxes.ROWID)
    public var account: String    // account email address
    public var name: String       // display path, e.g. "[Gmail]/All Mail"
    public var role: MailboxRole

    public init(id: Int64, account: String, name: String, role: MailboxRole) {
        self.id = id; self.account = account; self.name = name; self.role = role
    }
}

public struct MessageMeta: Codable, Sendable, Hashable, Identifiable {
    public var id: Int64          // Apple Mail: Envelope Index messages.ROWID == AppleScript `id` of the message
    public var mailbox: MailboxRef
    public var date: Date
    public var subject: String
    public var senderAddress: String
    public var senderName: String
    public var isRead: Bool
    public var isFlagged: Bool

    public init(id: Int64, mailbox: MailboxRef, date: Date, subject: String, senderAddress: String,
                senderName: String, isRead: Bool, isFlagged: Bool) {
        self.id = id; self.mailbox = mailbox; self.date = date; self.subject = subject
        self.senderAddress = senderAddress; self.senderName = senderName; self.isRead = isRead; self.isFlagged = isFlagged
    }
}

public struct ParsedMessage: Codable, Sendable {
    public var meta: MessageMeta
    public var to: [String]
    public var cc: [String]
    /// Readable plain text: text/plain part if present, else HTML stripped; quoted replies removed.
    public var bodyText: String
    /// Original HTML part when present (for the reader view).
    public var html: String?

    public init(meta: MessageMeta, to: [String], cc: [String], bodyText: String, html: String?) {
        self.meta = meta; self.to = to; self.cc = cc; self.bodyText = bodyText; self.html = html
    }
}

public enum MailAction: String, Codable, Sendable, CaseIterable {
    case trash, archive, markRead, markUnread, flag, unflag
    /// Move out of Trash back to the inbox.
    case restore
}

public struct ActionReport: Codable, Sendable {
    public var action: MailAction
    public var succeeded: [Int64]
    public var failed: [Int64: String]

    public init(action: MailAction, succeeded: [Int64], failed: [Int64: String]) {
        self.action = action; self.succeeded = succeeded; self.failed = failed
    }
}

public enum MailSourceError: Error, LocalizedError, Sendable {
    case fullDiskAccessRequired
    case messageFileMissing(Int64)
    case automationDenied
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired: "Full Disk Access is required to read Apple Mail data."
        case .messageFileMissing(let id): "Message file for \(id) is not on disk."
        case .automationDenied: "Permission to control Mail was denied."
        case .other(let s): s
        }
    }
}

/// A mail backend. Only Apple Mail is implemented in v1; Gmail (API) comes later.
public protocol MailSource: Sendable {
    var name: String { get }
    /// Throws `.fullDiskAccessRequired` when the store cannot be read.
    func checkAccess() throws
    /// Every searchable message (excludes trash, spam, drafts), newest first. Must be fast (metadata only).
    func listMessages() throws -> [MessageMeta]
    /// Messages currently in Trash mailboxes, newest first (metadata only; not part of the index).
    func listTrash() throws -> [MessageMeta]
    /// Full parse of one message.
    func parse(_ meta: MessageMeta) throws -> ParsedMessage
    /// Performs the action on exactly these message ids.
    func perform(_ action: MailAction, on ids: [Int64]) async throws -> ActionReport
}

/// Turns text into L2-normalized vectors. Documents and queries use different task prefixes.
public protocol TextEmbedder: Sendable {
    var dimension: Int { get }
    func embedDocuments(_ docs: [(title: String, body: String)]) async throws -> [[Float]]
    func embedQuery(_ query: String) async throws -> [Float]
}

// MARK: - Library facade (implemented in MailLibrary.swift)

public struct IndexStatus: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, syncing, embedding, done, failed }
    public var phase: Phase
    public var totalMessages: Int      // searchable messages known to the source
    public var keywordIndexed: Int     // parsed into full-text index
    public var vectorIndexed: Int      // have embeddings
    public var message: String?        // error or note

    public init(phase: Phase, totalMessages: Int, keywordIndexed: Int, vectorIndexed: Int, message: String? = nil) {
        self.phase = phase; self.totalMessages = totalMessages; self.keywordIndexed = keywordIndexed
        self.vectorIndexed = vectorIndexed; self.message = message
    }
}

public struct SearchHit: Codable, Sendable, Identifiable {
    public enum Match: String, Codable, Sendable { case semantic, keyword, both }
    public var meta: MessageMeta
    public var snippet: String
    public var score: Double
    public var match: Match
    public var id: Int64 { meta.id }

    public init(meta: MessageMeta, snippet: String, score: Double, match: Match) {
        self.meta = meta; self.snippet = snippet; self.score = score; self.match = match
    }
}

public struct SenderStat: Codable, Sendable, Identifiable {
    public var address: String
    public var name: String
    public var account: String
    public var count: Int
    public var latest: Date
    public var id: String { account + "|" + address }

    public init(address: String, name: String, account: String, count: Int, latest: Date) {
        self.address = address; self.name = name; self.account = account; self.count = count; self.latest = latest
    }
}

public struct SearchFilter: Codable, Sendable {
    public var account: String?
    public var sender: String?
    public var after: Date?
    public var before: Date?

    public init(account: String? = nil, sender: String? = nil, after: Date? = nil, before: Date? = nil) {
        self.account = account; self.sender = sender; self.after = after; self.before = before
    }
}
