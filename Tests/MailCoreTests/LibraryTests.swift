import XCTest
@testable import MailCore

final class LibraryTests: XCTestCase {
    func testSyncAddsRemovesAndUpdates() async throws {
        let source = FakeSource(messages: [
            .make(1, subject: "one"), .make(2, subject: "two"), .make(3, subject: "three"),
        ])
        let library = try makeLibrary(source, embedder: FakeEmbedder())
        try await library.runIndex()
        XCTAssertEqual(library.status().keywordIndexed, 3)
        XCTAssertEqual(library.status().vectorIndexed, 3)
        XCTAssertEqual(library.status().phase, .done)

        source.remove(2)
        source.add(.make(4, subject: "four"))
        source.setRead(1)
        source.parseCount = 0
        try await library.runIndex()
        XCTAssertEqual(source.parseCount, 1, "only the new message is parsed")
        XCTAssertEqual(library.status().keywordIndexed, 3)
        XCTAssertEqual(library.status().vectorIndexed, 3)
        let hits = try await library.search("two")
        XCTAssertFalse(hits.contains { $0.id == 2 })
        XCTAssertTrue(try library.message(id: 1).meta.isRead)
    }

    func testTraits() async throws {
        let source = FakeSource(messages: [
            .make(1, subject: "question", sender: "friend@example.com"),
            .make(2, subject: "Re: question", sender: "me@example.com"),
            .make(3, subject: "news", sender: "news@example.com"),
            .make(4, subject: "ask", sender: "me@example.com"),
        ])
        source.threads = [[1, 2]]
        source.lists = [3]
        let library = try makeLibrary(source, embedder: nil)
        try await library.sync()
        let metas = try (1...4).map { try library.message(id: Int64($0)).meta }
        let t = library.traits(metas)
        XCTAssertEqual(t[1]?.knownSender, true)
        XCTAssertEqual(t[1]?.repliedByMe, true)
        XCTAssertEqual(t[1]?.threadCount, 2)
        XCTAssertEqual(t[2]?.fromMe, true)
        XCTAssertEqual(t[2]?.repliedByMe, false)
        XCTAssertEqual(t[2]?.lastFromMe, true, "the user's reply is the latest: waiting for the friend")
        XCTAssertEqual(t[3]?.isList, true)
        XCTAssertEqual(t[3]?.knownSender, false)
        XCTAssertEqual(t[3]?.lastFromMe, false)
        XCTAssertEqual(t[4]?.lastFromMe, true)
        XCTAssertEqual(try library.thread(1).map(\.meta.id), [1, 2])
    }

    func testParseFailuresAreSkippedAndRetried() async throws {
        let source = FakeSource(messages: [.make(1, subject: "fine"), .make(2, subject: "broken")])
        source.failing = [2]
        let library = try makeLibrary(source, embedder: nil)
        try await library.sync()
        XCTAssertEqual(library.status().keywordIndexed, 1)
        XCTAssertEqual(library.status().totalMessages, 2)
        XCTAssertNotNil(library.status().message)
        source.failing = []
        try await library.sync()
        XCTAssertEqual(library.status().keywordIndexed, 2)
    }

    func testEmbeddingResumesAfterFailure() async throws {
        let source = FakeSource(messages: (1...600).map { .make(Int64($0), subject: "message \($0)") })
        let embedder = FakeEmbedder()
        embedder.failAfterCalls = 1
        let library = try makeLibrary(source, embedder: embedder)
        do {
            try await library.runIndex()
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(library.status().phase, .failed)
        XCTAssertEqual(library.status().vectorIndexed, MailLibrary.embedChunk, "first chunk was committed")

        embedder.failAfterCalls = nil
        embedder.embeddedCount = 0
        try await library.embedPending()
        XCTAssertEqual(embedder.embeddedCount, 600 - MailLibrary.embedChunk)
        XCTAssertEqual(library.status().vectorIndexed, 600)
    }

    func testNewestEmbeddedFirst() async throws {
        let source = FakeSource(messages: (1...300).map { .make(Int64($0), subject: "m\($0)") })
        let embedder = FakeEmbedder()
        embedder.failAfterCalls = 1
        let library = try makeLibrary(source, embedder: embedder)
        try? await library.runIndex()
        // FakeSource dates grow with id, so the first chunk holds the 256 highest ids.
        XCTAssertEqual(Set(embedder.titles), Set((45...300).map { "m\($0)" }))
    }

    func testConcurrentIndexRunsAreRejected() async throws {
        let source = FakeSource(messages: [.make(1, subject: "one")])
        let embedder = FakeEmbedder()
        embedder.delay = 0.5
        let library = try makeLibrary(source, embedder: embedder)
        let first = Task { try await library.runIndex() }
        try await Task.sleep(nanoseconds: 100_000_000)
        do {
            try await library.sync()
            XCTFail("expected indexingInProgress")
        } catch MailLibraryError.indexingInProgress {}
        try await first.value
    }

    func testTrashRemovesFromIndexAndSenderListingMatches() async throws {
        let source = FakeSource(messages: [
            .make(1, subject: "promo a", sender: "News@Shop.com"), .make(2, subject: "promo b", sender: "news@shop.com"),
            .make(3, subject: "hello", sender: "friend@x.com"),
        ])
        let library = try makeLibrary(source, embedder: FakeEmbedder())
        try await library.runIndex()
        let stats = library.senders()
        XCTAssertEqual(stats.first?.count, 2)
        let targets = library.messages(fromSender: "news@shop.com", account: nil)
        XCTAssertEqual(Set(targets.map(\.id)), [1, 2])
        let report = try await library.perform(.trash, ids: targets.map(\.id))
        XCTAssertEqual(Set(report.succeeded), [1, 2])
        XCTAssertEqual(Set(source.trashed), [1, 2])
        XCTAssertTrue(library.messages(fromSender: "news@shop.com", account: nil).isEmpty)
        XCTAssertEqual(library.status().vectorIndexed, 1)
        let hits = try await library.search("promo")
        XCTAssertEqual(hits.map(\.id), [3], "only the remaining message, via semantic nearest neighbours")
    }

    func testMessageFallsBackToStoredBody() async throws {
        let source = FakeSource(messages: [.make(1, subject: "s", body: "stored body")])
        let library = try makeLibrary(source, embedder: nil)
        try await library.sync()
        source.failing = [1]
        let message = try library.message(id: 1)
        XCTAssertEqual(message.bodyText, "stored body")
        XCTAssertNil(message.html)
        XCTAssertThrowsError(try library.message(id: 99))
    }
}

// MARK: - Fakes shared by the MailCore tests

func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mailsift-test-\(UUID().uuidString)/index.sqlite")
}

func makeLibrary(_ source: FakeSource, embedder: TextEmbedder?) throws -> MailLibrary {
    try MailLibrary(source: source, embedder: embedder, databaseURL: temporaryDatabaseURL())
}

extension ParsedMessage {
    static func make(
        _ id: Int64, subject: String, body: String? = nil, sender: String = "someone@example.com",
        account: String = "me@example.com", date: Date? = nil
    ) -> ParsedMessage {
        let mailbox = MailboxRef(id: 1, account: account, name: "INBOX", role: .inbox)
        let meta = MessageMeta(
            id: id, mailbox: mailbox, date: date ?? Date(timeIntervalSince1970: 1_700_000_000 + Double(id) * 60),
            subject: subject, senderAddress: sender, senderName: sender.components(separatedBy: "@")[0],
            isRead: false, isFlagged: false)
        return ParsedMessage(meta: meta, to: [], cc: [], bodyText: body ?? "Body of \(subject).", html: "<p>\(subject)</p>")
    }
}

final class FakeSource: MailSource, @unchecked Sendable {
    let name = "fake"
    private let lock = NSLock()
    private var messages: [Int64: ParsedMessage]
    private var _failing: Set<Int64> = []
    private var _parseCount = 0
    private(set) var trashed: [Int64] = []

    init(messages: [ParsedMessage]) {
        self.messages = Dictionary(uniqueKeysWithValues: messages.map { ($0.meta.id, $0) })
    }

    var failing: Set<Int64> {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    var parseCount: Int {
        get { lock.withLock { _parseCount } }
        set { lock.withLock { _parseCount = newValue } }
    }

    func add(_ message: ParsedMessage) { lock.withLock { messages[message.meta.id] = message } }
    func remove(_ id: Int64) { lock.withLock { _ = messages.removeValue(forKey: id) } }
    func setRead(_ id: Int64) { lock.withLock { messages[id]?.meta.isRead = true } }

    func checkAccess() throws {}

    var threads: [[Int64]] = []
    var lists: Set<Int64> = []

    func signals(_ ids: [Int64]) throws -> [Int64: SourceSignals] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, SourceSignals(isList: lists.contains(id), thread: threads.first { $0.contains(id) } ?? [id]))
        })
    }

    func correspondents() throws -> Set<String> { ["friend@example.com"] }

    func listMessages() throws -> [MessageMeta] {
        lock.withLock { messages.values.map(\.meta).sorted { $0.date > $1.date } }
    }

    func listMailbox(_ role: MailboxRole) throws -> [MessageMeta] { [] }

    func compose(_ kind: ComposeKind, id: Int64, body: String?) async throws {}

    func parse(_ meta: MessageMeta) throws -> ParsedMessage {
        try lock.withLock {
            _parseCount += 1
            guard !_failing.contains(meta.id), let message = messages[meta.id] else {
                throw MailSourceError.messageFileMissing(meta.id)
            }
            return message
        }
    }

    func attachmentFile(_ meta: MessageMeta, _ attachment: Attachment) throws -> URL {
        throw MailSourceError.other("Not downloaded by Mail yet")
    }

    func downloadAttachment(_ meta: MessageMeta, _ attachment: Attachment) async throws -> URL {
        throw MailSourceError.other("Not downloaded by Mail yet")
    }

    func perform(_ action: MailAction, on ids: [Int64]) async throws -> ActionReport {
        lock.withLock {
            if action == .trash {
                trashed += ids
                for id in ids { messages.removeValue(forKey: id) }
            }
        }
        return ActionReport(action: action, succeeded: ids, failed: [:])
    }
}

/// Deterministic bag-of-words embedder: words (and single CJK characters) hashed into 64 buckets, normalized.
final class FakeEmbedder: TextEmbedder, @unchecked Sendable {
    let dimension = 64
    private let lock = NSLock()
    var failAfterCalls: Int?
    var delay: Double = 0
    var embeddedCount = 0
    var titles: [String] = []
    private var calls = 0

    func embedDocuments(_ docs: [(title: String, body: String)]) async throws -> [[Float]] {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        try lock.withLock {
            if let limit = failAfterCalls, calls >= limit { throw MailSourceError.other("embedder failed") }
            calls += 1
            embeddedCount += docs.count
            titles += docs.map(\.title)
        }
        return docs.map { Self.vector("\($0.title) \($0.body)") }
    }

    func embedQuery(_ query: String) async throws -> [Float] { Self.vector(query) }

    static func vector(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: 64)
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let hash = word.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
            vector[Int(hash % 64)] += 1
            word = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
                flush()
                word = String(scalar)
                flush()
            } else if CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        let norm = vector.map { $0 * $0 }.reduce(0, +).squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }
}
