import SQLite3
import XCTest
@testable import MailCore

final class StoreTests: XCTestCase {
    func testTrigramFTSHandlesChinese() throws {
        print("sqlite", String(cString: sqlite3_libversion()))
        let store = try IndexStore(url: temporaryDatabaseURL())
        try store.upsert([
            .make(1, subject: "本期信用卡帳單", body: "您的繳款金額為 NT$1,234"),
            .make(2, subject: "Cloud invoice", body: "Your invoice is ready"),
        ])
        XCTAssertEqual(try store.fullTextSearch(["信用卡"], filter: .init(), limit: 10), [1])
        XCTAssertEqual(try store.fullTextSearch(["INVOICE"], filter: .init(), limit: 10), [2])
        XCTAssertEqual(try store.fullTextSearch(["信用卡", "invoice"], filter: .init(), limit: 10).sorted(), [1, 2])
        XCTAssertEqual(try store.substringSearch(["帳單"], filter: .init(), limit: 10), [1])
        XCTAssertEqual(try store.substringSearch(["50%"], filter: .init(), limit: 10), [], "LIKE wildcards are escaped")
    }

    func testDeleteRemovesTextAndVectors() throws {
        let store = try IndexStore(url: temporaryDatabaseURL())
        try store.upsert([.make(1, subject: "delete me please"), .make(2, subject: "keep me please")])
        try store.setVectors([(1, [1, 0]), (2, [0, 1])])
        try store.delete([1])
        XCTAssertEqual(try store.fullTextSearch(["please"], filter: .init(), limit: 10), [2])
        XCTAssertEqual(try store.allIDs(), [2])
        XCTAssertEqual(try store.counts().vectors, 1)
    }

    func testUpsertReplacesText() throws {
        let store = try IndexStore(url: temporaryDatabaseURL())
        try store.upsert([.make(1, subject: "old subject")])
        try store.upsert([.make(1, subject: "new subject")])
        XCTAssertEqual(try store.fullTextSearch(["old"], filter: .init(), limit: 10), [])
        XCTAssertEqual(try store.fullTextSearch(["new"], filter: .init(), limit: 10), [1])
    }

    func testVectorsMissingNewestFirstAndUnknownIDsSkipped() throws {
        let store = try IndexStore(url: temporaryDatabaseURL())
        try store.upsert([.make(1, subject: "a"), .make(2, subject: "b"), .make(3, subject: "c")])
        try store.setVectors([(2, [1, 0]), (99, [0, 1])])
        XCTAssertEqual(try store.idsMissingVectors(), [3, 1])
        XCTAssertEqual(try store.counts().vectors, 1)
        var matrix: [Float] = []
        var ids: [Int64] = []
        _ = try store.vectors(after: 0, upTo: .max, into: &matrix, ids: &ids)
        XCTAssertEqual(ids, [2])
        XCTAssertEqual(matrix, [1, 0])
    }

    func testSenderStatsGroupCaseInsensitively() throws {
        let store = try IndexStore(url: temporaryDatabaseURL())
        try store.upsert([
            .make(1, subject: "a", sender: "Bob@x.com"), .make(2, subject: "b", sender: "bob@x.com"),
            .make(3, subject: "c", sender: "amy@y.com"), .make(4, subject: "d", sender: "bob@x.com", account: "work@z.com"),
        ])
        let all = try store.senderStats(account: nil, limit: 10)
        XCTAssertEqual(all.count, 3, "same address in two accounts stays separate")
        XCTAssertEqual(all[0].count, 2)
        XCTAssertEqual(all[0].latest, Date(timeIntervalSince1970: 1_700_000_000 + 2 * 60))
        XCTAssertEqual(try store.senderStats(account: "work@z.com", limit: 10).map(\.count), [1])
        XCTAssertEqual(try store.metas(fromSender: "BOB@X.COM", account: "me@example.com").map(\.id), [2, 1])
    }
}
