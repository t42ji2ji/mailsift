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
    private let searcher: Searcher
    private let lock = NSLock()
    private var embedder: TextEmbedder?
    private var current: IndexStatus
    private var indexing = false

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

    // MARK: - Indexing

    /// Brings the keyword index in line with the source: removes messages that are gone, adds new ones.
    public func sync(progress: Progress? = nil) async throws {
        try await indexRun(progress) { try await self.syncMessages(progress) }
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
        let metas = try source.listMessages()
        let stored = try store.allIDs()
        let gone = stored.subtracting(metas.map(\.id))
        if !gone.isEmpty {
            try store.delete(Array(gone))
            searcher.invalidate()
        }
        try store.updateMeta(metas.filter { stored.contains($0.id) })
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
    public func recent(limit: Int = 400) -> [SearchHit] {
        ((try? store.recent(limit: limit)) ?? []).map {
            SearchHit(meta: $0.meta, snippet: Searcher.snippet($0.body, terms: []), score: 0, match: .keyword)
        }
    }

    public func attachmentFile(_ meta: MessageMeta, _ attachment: Attachment) throws -> URL {
        try source.attachmentFile(meta, attachment)
    }

    /// What is in Trash right now, straight from the source.
    public func trash() -> [MessageMeta] {
        (try? source.listTrash()) ?? []
    }

    /// Full message from the source (with HTML); the stored text when the source cannot parse it.
    public func message(id: Int64) throws -> ParsedMessage {
        guard let row = try store.metaAndBody([id])[id] else { throw MailLibraryError.notIndexed(id) }
        if let parsed = try? source.parse(row.meta) { return parsed }
        return ParsedMessage(meta: row.meta, to: [], cc: [], bodyText: row.body, html: nil)
    }

    /// Senders by message count (address compared case-insensitively, per account).
    public func senders(account: String? = nil, limit: Int = 200) -> [SenderStat] {
        (try? store.senderStats(account: account, limit: limit)) ?? []
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
        switch action {
        case .trash:
            try store.delete(done)
            searcher.invalidate()
            try refreshCounts(nil) { $0.totalMessages = max($0.totalMessages - done.count, 0) }
        case .markRead: try store.setFlags(done, isRead: true)
        case .markUnread: try store.setFlags(done, isRead: false)
        case .flag: try store.setFlags(done, isFlagged: true)
        case .unflag: try store.setFlags(done, isFlagged: false)
        case .archive, .restore: break  // the new mailbox is picked up by the next sync
        }
        return result
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
