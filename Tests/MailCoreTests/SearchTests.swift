import XCTest
@testable import MailCore

final class SearchTests: XCTestCase {
    private func library(embedder: TextEmbedder? = FakeEmbedder()) async throws -> MailLibrary {
        let source = FakeSource(messages: [
            .make(1, subject: "Cloud invoice for March", body: "Your cloud invoice total is $20.", sender: "billing@cloud.com"),
            .make(2, subject: "信用卡帳單", body: "本期帳單繳款金額 1234 元", sender: "bank@bank.tw"),
            .make(3, subject: "Lunch?", body: "Want to grab lunch tomorrow", sender: "friend@x.com",
                  account: "work@z.com"),
            .make(4, subject: "Jira task assigned", body: "A task was assigned to you in project MAIL", sender: "jira@x.com"),
        ])
        let library = try makeLibrary(source, embedder: embedder)
        try await library.runIndex()
        return library
    }

    func testMultiWordQueryMatchesAnyTerm() async throws {
        let hits = try await library(embedder: nil).search("invoice lunch")
        XCTAssertEqual(Set(hits.map(\.id)), [1, 3])
        XCTAssertTrue(hits.allSatisfy { $0.match == .keyword })
    }

    func testShortChineseTermFallsBackToSubstring() async throws {
        let hits = try await library(embedder: nil).search("帳單")
        XCTAssertEqual(hits.map(\.id), [2])
        XCTAssertTrue(hits[0].snippet.contains("帳單"))
    }

    func testHybridLabelsAndRanking() async throws {
        let hits = try await library().search("cloud invoice")
        XCTAssertEqual(hits.first?.id, 1)
        XCTAssertEqual(hits.first?.match, .both)
        XCTAssertTrue(hits.dropFirst().allSatisfy { $0.match == .semantic })
        XCTAssertGreaterThan(hits[0].score, hits.last!.score)
    }

    func testFiltersApplyToBothLists() async throws {
        let lib = try await library()
        let byAccount = try await lib.search("lunch invoice", filter: .init(account: "work@z.com"))
        XCTAssertEqual(byAccount.map(\.id), [3])
        let bySender = try await lib.search("task", filter: .init(sender: "JIRA"))
        XCTAssertEqual(bySender.map(\.id), [4])
        let after = Date(timeIntervalSince1970: 1_700_000_000 + 2.5 * 60)
        let byDate = try await lib.search("invoice lunch task", filter: .init(after: after))
        XCTAssertEqual(Set(byDate.map(\.id)), [3, 4])
    }

    func testSnippetCentersOnHit() {
        let body = String(repeating: "filler ", count: 50) + "the needle is here" + String(repeating: " tail", count: 50)
        let snippet = Searcher.snippet(body, terms: ["NEEDLE"])
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.contains("needle"))
        XCTAssertEqual(Searcher.snippet("short  body\n text", terms: []), "short body text")
    }

    /// Brute-force cosine over a synthetic 40k × 768 matrix.
    func testNearestLatencyAt40k() throws {
        let rows = 40_000, dimension = 768
        let store = try IndexStore(url: temporaryDatabaseURL())
        var generator = SystemRandomNumberGenerator()
        func random() -> [Float] {
            let v = (0..<dimension).map { _ in Float.random(in: -1...1, using: &generator) }
            let norm = v.map { $0 * $0 }.reduce(0, +).squareRoot()
            return v.map { $0 / norm }
        }
        for start in stride(from: 0, to: rows, by: 5_000) {
            let ids = (start..<start + 5_000).map(Int64.init)
            try store.upsert(ids.map { .make($0, subject: "s", body: "") })
            try store.setVectors(ids.map { ($0, random()) })
        }
        let searcher = Searcher(store: store)
        var start = Date()
        _ = try searcher.nearest(random(), allowed: nil, limit: 100)
        print("initial load + search: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        start = Date()
        let runs = 20
        for _ in 0..<runs { XCTAssertEqual(try searcher.nearest(random(), allowed: nil, limit: 100).count, 100) }
        print("nearest at 40k × 768: \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000 / Double(runs))) ms per query")
    }
}
