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
    /// In the inbox (Gmail: carries the INBOX label). Searchable mail that isn't is archived.
    public var inInbox: Bool

    public init(id: Int64, mailbox: MailboxRef, date: Date, subject: String, senderAddress: String,
                senderName: String, isRead: Bool, isFlagged: Bool, inInbox: Bool = true) {
        self.id = id; self.mailbox = mailbox; self.date = date; self.subject = subject
        self.senderAddress = senderAddress; self.senderName = senderName; self.isRead = isRead; self.isFlagged = isFlagged
        self.inInbox = inInbox
    }
}

public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    /// MIME part number as IMAP numbers it ("2", "2.3"); also the folder name Mail uses under Attachments/<id>/.
    public var part: String
    public var filename: String
    public var mimeType: String
    /// Decoded size in bytes when known.
    public var size: Int?
    /// Content-ID without angle brackets, for `cid:` references in the HTML.
    public var contentID: String?
    public var isInline: Bool
    /// False when Mail has not downloaded the content yet (partial message, no file in Attachments/).
    public var isDownloaded: Bool
    public var id: String { part }

    public init(part: String, filename: String, mimeType: String, size: Int?, contentID: String?, isInline: Bool, isDownloaded: Bool) {
        self.part = part; self.filename = filename; self.mimeType = mimeType; self.size = size
        self.contentID = contentID; self.isInline = isInline; self.isDownloaded = isDownloaded
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
    /// Every non-body part: files and inline images. Metadata only; content via `MailSource.attachmentFile`.
    public var attachments: [Attachment]

    public init(meta: MessageMeta, to: [String], cc: [String], bodyText: String, html: String?, attachments: [Attachment] = []) {
        self.meta = meta; self.to = to; self.cc = cc; self.bodyText = bodyText; self.html = html; self.attachments = attachments
    }
}

public enum MailAction: String, Codable, Sendable, CaseIterable {
    case trash, archive, markRead, markUnread, flag, unflag
    /// Move out of Trash back to the inbox.
    case restore
    /// Mark as junk and move to the account's Spam mailbox.
    case junk
}

/// Writing in Mail.app: it owns the accounts and sending, MailSift only opens the window.
public enum ComposeKind: String, Codable, Sendable, CaseIterable {
    case reply, replyAll, forward
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
    /// Messages in mailboxes of `role` (.trash, .spam), newest first. Metadata only; these aren't indexed.
    func listMailbox(_ role: MailboxRole) throws -> [MessageMeta]
    /// Full parse of one message.
    func parse(_ meta: MessageMeta) throws -> ParsedMessage
    /// A readable file with the attachment's content: Mail's own copy when it exists, otherwise decoded from the
    /// message into a cache folder. Throws when the content isn't on disk (not downloaded by Mail yet).
    func attachmentFile(_ meta: MessageMeta, _ attachment: Attachment) throws -> URL
    /// Has the mail client fetch an attachment it hasn't downloaded yet, then returns a file with its content.
    func downloadAttachment(_ meta: MessageMeta, _ attachment: Attachment) async throws -> URL
    /// Opens a reply/forward window for `id` in the mail client, with `body` above the quoted original. Never sends.
    func compose(_ kind: ComposeKind, id: Int64, body: String?) async throws
    /// Performs the action on exactly these message ids.
    func perform(_ action: MailAction, on ids: [Int64]) async throws -> ActionReport
    /// Mailing-list membership and conversation for these ids; ids the source doesn't know are left out.
    func signals(_ ids: [Int64]) throws -> [Int64: SourceSignals]
    /// Addresses (lowercased) the user has sent mail to.
    func correspondents() throws -> Set<String>
}

public extension MailSource {
    func signals(_ ids: [Int64]) throws -> [Int64: SourceSignals] { [:] }
    func correspondents() throws -> Set<String> { [] }
}

/// What the mail client knows beyond the headers MailSift indexes.
public struct SourceSignals: Sendable {
    /// Sent to a mailing list (List-Id): newsletters, notifications, groups.
    public var isList: Bool
    /// Every message in the same conversation, this one included.
    public var thread: [Int64]

    public init(isList: Bool, thread: [Int64]) {
        self.isList = isList; self.thread = thread
    }
}

/// Triage facts about one message, from the source's signals and the index.
public struct MailTraits: Codable, Sendable {
    public var isList: Bool
    public var fromMe: Bool
    /// The user has sent mail to this sender.
    public var knownSender: Bool
    /// Indexed messages in the conversation (trash and spam are not indexed).
    public var threadCount: Int
    /// The user wrote in the conversation after this message.
    public var repliedByMe: Bool
    /// The conversation's latest message is the user's: they are waiting for an answer.
    public var lastFromMe: Bool
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
    public var unread: Int
    public var latest: Date
    public var id: String { account + "|" + address }

    public init(address: String, name: String, account: String, count: Int, unread: Int = 0, latest: Date) {
        self.address = address; self.name = name; self.account = account; self.count = count; self.unread = unread
        self.latest = latest
    }
}

/// Views over the index: inbox, flagged, archive (searchable mail not in the inbox).
public enum BrowseBox: String, Codable, Sendable, CaseIterable {
    case inbox, flagged, archive
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
