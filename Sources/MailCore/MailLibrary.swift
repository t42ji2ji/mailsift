import Foundation

public enum MailLibraryError: Error, LocalizedError {
    case indexingInProgress
    case notIndexed(Int64)

    public var errorDescription: String? {
        switch self {
        case .indexingInProgress: "Indexing is already running."
        case .notIndexed(let id): "Message \(id) is not in the index."
        }
    }
}

/// The one entry point for the CLI, the MCP server and the app: indexing, search, sender stats and mail actions.
public final class MailLibrary: @unchecked Sendable {
    public typealias Progress = @Sendable (IndexStatus) -> Void

    static let syncChunk = 500
    static let embedChunk = 256
    /// Characters of body text embedded per message; the tokenizer stops at 512 tokens anyway.
    static let embedBodyLength = 2000

    public let source: MailSource
    let store: IndexStore
    let searcher: Searcher
    private let lock = NSLock()
    var embedder: TextEmbedder?
    private var current: IndexStatus
    private var indexing = false
    /// The source's change token at the last sync that finished, and when.
    private var synced: (token: String, at: Date)?
    /// Each message's meta as sync last wrote it, so later syncs write only what changed: a row update rewrites the
    /// whole row, body included.
    private var writtenMeta: [Int64: Int] = [:]

    public init(source: MailSource, embedder: TextEmbedder?, databaseURL: URL = MailLibrary.defaultDatabaseURL()) throws {
        self.source = source
        self.embedder = embedder
        store = try IndexStore(url: databaseURL)
        searcher = Searcher(store: store)
        let counts = try store.counts()
        current = IndexStatus(phase: .idle, totalMessages: counts.messages, keywordIndexed: counts.messages,
                              vectorIndexed: counts.vectors)
    }

    /// ~/Library/Application Support/MailSift/index.sqlite
    public static func defaultDatabaseURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailSift/index.sqlite")
    }

    public func status() -> IndexStatus { locked { current } }

    /// The embedding model may finish loading after the library is created.
    public func setEmbedder(_ embedder: TextEmbedder?) { locked { self.embedder = embedder } }

    public var canSearchByMeaning: Bool { locked { embedder != nil } }

    // MARK: - Indexing

    /// Brings the keyword index in line with the source: removes messages that are gone, adds new ones.
    /// Skipped when the source reports no change since the last sync, up to ten minutes (a message file can land
    /// after its row without the store changing again). Returns whether it read the source.
    @discardableResult
    public func sync(force: Bool = false, progress: Progress? = nil) async throws -> Bool {
        let token = source.changeToken()
        if !force, let token, let synced = locked({ synced }), synced.token == token,
           Date().timeIntervalSince(synced.at) < 600 {
            return false
        }
        try await indexRun(progress) { try await self.syncMessages(progress) }
        if let token { locked { synced = (token, Date()) } }
        return true
    }

    /// Embeds messages that have no vector yet, newest first. Cancellable; resumes where it stopped.
    public func embedPending(progress: Progress? = nil) async throws {
        try await indexRun(progress) { try await self.embedMessages(progress) }
    }

    public func runIndex(progress: Progress? = nil) async throws {
        try await indexRun(progress) {
            try await self.syncMessages(progress)
            try await self.embedMessages(progress)
        }
    }

    private func indexRun(_ progress: Progress?, _ body: () async throws -> Void) async throws {
        try locked {
            guard !indexing else { throw MailLibraryError.indexingInProgress }
            indexing = true
        }
        defer { locked { indexing = false } }
        do {
            try await body()
            report(progress) { $0.phase = .done }
        } catch is CancellationError {
            report(progress) { $0.phase = .idle; $0.message = "Cancelled." }
            throw CancellationError()
        } catch {
            report(progress) { $0.phase = .failed; $0.message = error.localizedDescription }
            throw error
        }
    }

    private func syncMessages(_ progress: Progress?) async throws {
        report(progress) { $0.phase = .syncing; $0.message = nil }
        try store.upgradeKeywordIndex()
        let metas = try source.listMessages()
        let stored = try store.allIDs()
        let gone = stored.subtracting(metas.map(\.id))
        if !gone.isEmpty {
            try store.delete(Array(gone))
            searcher.invalidate()
        }
        let existing = metas.filter { stored.contains($0.id) }
        try store.updateMeta(locked { existing.filter { writtenMeta[$0.id] != $0.hashValue } })
        locked { writtenMeta = existing.reduce(into: [:]) { $0[$1.id] = $1.hashValue } }
        try refreshCounts(progress) { $0.totalMessages = metas.count }

        let new = metas.filter { !stored.contains($0.id) }
        var failed = 0
        for start in stride(from: 0, to: new.count, by: Self.syncChunk) {
            try Task.checkCancellation()
            let chunk = Array(new[start..<min(start + Self.syncChunk, new.count)])
            // Parsing reads and decodes message files; spread it over the cores. Failures are skipped (and retried
            // on the next sync).
            let ok = await withTaskGroup(of: ParsedMessage?.self) { group in
                for meta in chunk { group.addTask { try? self.source.parse(meta) } }
                return await group.reduce(into: [ParsedMessage]()) { if let message = $1 { $0.append(message) } }
            }
            failed += chunk.count - ok.count
            try store.upsert(ok)
            try refreshCounts(progress) {
                $0.message = failed > 0 ? "\(failed) messages could not be read." : nil
            }
        }
    }

    private func embedMessages(_ progress: Progress?) async throws {
        guard let embedder = locked({ embedder }) else {
            report(progress) { $0.message = "Embedding model not loaded; keyword search only." }
            return
        }
        report(progress) { $0.phase = .embedding }
        let pending = try store.idsMissingVectors()
        for start in stride(from: 0, to: pending.count, by: Self.embedChunk) {
            try Task.checkCancellation()
            let docs = try store.documents(Array(pending[start..<min(start + Self.embedChunk, pending.count)]))
            let vectors = try await embedder.embedDocuments(
                docs.map { (title: $0.subject, body: String($0.body.prefix(Self.embedBodyLength))) })
            try store.setVectors(zip(docs, vectors).map { (id: $0.id, vector: $1) })
            try refreshCounts(progress)
        }
        // Also relabel when there are no labels yet or the categories changed since they were made.
        let signature = categorySignature()
        if try !pending.isEmpty || store.categoryIDs().isEmpty || store.setting("categorySignature") != signature {
            try store.setCategories(try await categorize())
            try store.setSetting("categorySignature", signature)
        }
    }

    private func refreshCounts(_ progress: Progress?, _ change: (inout IndexStatus) -> Void = { _ in }) throws {
        let counts = try store.counts()
        report(progress) {
            $0.keywordIndexed = counts.messages
            $0.vectorIndexed = counts.vectors
            change(&$0)
        }
    }

    private func report(_ progress: Progress?, _ change: (inout IndexStatus) -> Void) {
        let status = locked {
            change(&current)
            return current
        }
        progress?(status)
    }

    // MARK: - Reading

    public func search(_ query: String, filter: SearchFilter = .init(), limit: Int = 30) async throws -> [SearchHit] {
        try await searcher.search(query, filter: filter, limit: limit, embedder: locked { embedder })
    }

    /// Newest messages, for browsing before any query.
    public func recent(_ box: BrowseBox = .inbox, limit: Int = 400, offset: Int = 0, excludingFlagged: Bool = false, isRead: Bool? = nil,
                       accounts: [String]? = nil, category: String? = nil) -> [SearchHit] {
        ((try? store.recent(box, limit: limit, offset: offset, excludingFlagged: excludingFlagged, isRead: isRead,
                            accounts: accounts, category: category)) ?? []).map {
            SearchHit(meta: $0.meta, snippet: Searcher.snippet($0.body, terms: []), score: 0, match: .keyword)
        }
    }

    /// How many messages are in a browse box.
    public func count(_ box: BrowseBox, accounts: [String]? = nil, category: String? = nil) -> Int {
        (try? store.count(box, accounts: accounts, category: category)) ?? 0
    }

    public func attachmentFile(_ meta: MessageMeta, _ attachment: Attachment) throws -> URL {
        try source.attachmentFile(meta, attachment)
    }

    public func downloadAttachment(_ meta: MessageMeta, _ attachment: Attachment) async throws -> URL {
        try await source.downloadAttachment(meta, attachment)
    }

    public func compose(_ kind: ComposeKind, id: Int64, body: String? = nil) async throws {
        try await source.compose(kind, id: id, body: body)
    }

    /// What is in Trash right now, straight from the source.
    public func trash() -> [MessageMeta] { mailbox(.trash) }

    /// Unindexed mailboxes (.trash, .spam), straight from the source.
    public func mailbox(_ role: MailboxRole) -> [MessageMeta] {
        (try? source.listMailbox(role)) ?? []
    }

    /// Full message from the source (with HTML); the stored text when the source cannot parse it.
    public func message(id: Int64) throws -> ParsedMessage {
        guard let row = try store.metaAndBody([id])[id] else { throw MailLibraryError.notIndexed(id) }
        if let parsed = try? source.parse(row.meta) { return parsed }
        return ParsedMessage(meta: row.meta, to: [], cc: [], bodyText: row.body, html: nil)
    }

    /// Accounts with indexed mail, most mail first.
    public func accounts() -> [String] { (try? store.accountList()) ?? [] }

    /// Accounts set up in the mail client with no indexed mail yet: the client is still downloading them.
    public func syncingAccounts(indexed: [String]) -> [String] {
        let indexed = Set(indexed)
        return ((try? source.accounts()) ?? []).filter { !indexed.contains($0) }
    }

    /// Senders by message count (address compared case-insensitively, per account), optionally only since `after`.
    public func senders(account: String? = nil, after: Date? = nil, limit: Int = 200) -> [SenderStat] {
        (try? store.senderStats(account: account, after: after, limit: limit)) ?? []
    }

    /// Addresses (lowercased) the user has sent mail to.
    public func correspondents() -> Set<String> {
        (try? source.correspondents()) ?? []
    }

    /// Triage facts for these messages. A conversation only counts indexed messages: sent mail is in, trash and
    /// spam are not.
    public func traits(_ metas: [MessageMeta]) -> [Int64: MailTraits] {
        let signals = (try? source.signals(metas.map(\.id))) ?? [:]
        let known = correspondents()
        let mine = (try? store.accounts()) ?? []
        let members = (try? store.metas(Array(Set(signals.values.flatMap(\.thread))))) ?? [:]
        func fromMe(_ m: MessageMeta) -> Bool { mine.contains(m.senderAddress.lowercased()) }
        var result: [Int64: MailTraits] = [:]
        for meta in metas {
            let thread = (signals[meta.id]?.thread ?? []).compactMap { members[$0] }.sorted { $0.date < $1.date }
            result[meta.id] = MailTraits(
                isList: signals[meta.id]?.isList ?? false, fromMe: fromMe(meta),
                knownSender: known.contains(meta.senderAddress.lowercased()),
                threadCount: max(thread.count, 1),
                repliedByMe: thread.contains { fromMe($0) && $0.date > meta.date },
                lastFromMe: thread.last.map(fromMe) ?? fromMe(meta))
        }
        return result
    }

    /// The conversation `id` is in, oldest first, with stored body text.
    public func thread(_ id: Int64) throws -> [ParsedMessage] {
        let ids = (try source.signals([id]))[id]?.thread ?? [id]
        return try store.metaAndBody(ids).values
            .sorted { $0.meta.date < $1.meta.date }
            .map { ParsedMessage(meta: $0.meta, to: [], cc: [], bodyText: $0.body, html: nil) }
    }

    /// Every indexed message from `address` (case-insensitive), newest first. Pass exactly these ids to `perform`.
    public func messages(fromSender address: String, account: String?) -> [MessageMeta] {
        (try? store.metas(fromSender: address, account: account)) ?? []
    }

    // MARK: - Actions

    /// Runs `action` on exactly `ids` through the source and mirrors the result in the index.
    public func perform(_ action: MailAction, ids: [Int64]) async throws -> ActionReport {
        let result = try await source.perform(action, on: ids)
        let done = result.succeeded
        // The index now differs from what sync wrote; the next sync writes these again.
        locked { for id in done { writtenMeta[id] = nil } }
        switch action {
        case .trash, .junk:  // neither Trash nor Spam is indexed
            try store.delete(done)
            searcher.invalidate()
            try refreshCounts(nil) { $0.totalMessages = max($0.totalMessages - done.count, 0) }
        case .archive: try store.setFlags(done, inInbox: false)
        case .markRead: try store.setFlags(done, isRead: true)
        case .markUnread: try store.setFlags(done, isRead: false)
        case .flag: try store.setFlags(done, isFlagged: true)
        case .unflag: try store.setFlags(done, isFlagged: false)
        case .restore: break  // restored mail is picked up by the next sync
        case .deletePermanently: break  // Trash isn't indexed
        }
        return result
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
