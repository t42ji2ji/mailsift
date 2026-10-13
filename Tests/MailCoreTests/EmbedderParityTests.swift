import XCTest
@testable import MailCore

/// Compares Core ML vectors with sentence-transformers reference vectors (private fixture, same prefix rule).
/// Run with EMBEDDINGGEMMA2_MODEL_DIR set; skipped otherwise so the suite never triggers the model download.
final class EmbedderParityTests: XCTestCase {
    struct Fixture: Decodable {
        struct Doc: Decodable { let title: String; let body: String; let vector: [Float] }
        struct Query: Decodable { let text: String; let vector: [Float] }
        let docs: [Doc]
        let queries: [Query]
    }

    func testParityAndThroughput() async throws {
        guard ProcessInfo.processInfo.environment["EMBEDDINGGEMMA2_MODEL_DIR"] != nil else {
            throw XCTSkip("EMBEDDINGGEMMA2_MODEL_DIR not set")
        }
        let url = URL(fileURLWithPath: "/Users/dora/me/mail-search/fixtures/ref_vectors.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("fixture missing") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let embedder = try await CoreMLEmbedder.load()

        let docs = fixture.docs.map { (title: $0.title == "none" ? "" : $0.title, body: $0.body) }
        let docVectors = try await embedder.embedDocuments(docs)
        var cosines: [Float] = []
        for (vector, doc) in zip(docVectors, fixture.docs) { cosines.append(cosine(vector, doc.vector)) }
        var agree = 0
        for query in fixture.queries {
            let vector = try await embedder.embedQuery(query.text)
            cosines.append(cosine(vector, query.vector))
            if argmax(docVectors, vector) == argmax(fixture.docs.map(\.vector), query.vector) { agree += 1 }
        }
        let mean = cosines.reduce(0, +) / Float(cosines.count)
        print("parity: min cosine \(cosines.min()!), mean \(mean), top-1 agreement \(agree)/\(fixture.queries.count)")
        XCTAssertGreaterThanOrEqual(cosines.min()!, 0.99)
        XCTAssertEqual(agree, fixture.queries.count)

        let batch = Array(repeating: docs, count: 21).flatMap { $0 }  // 504 docs
        let start = Date()
        _ = try await embedder.embedDocuments(batch)
        let seconds = Date().timeIntervalSince(start)
        print("throughput: \(batch.count) docs in \(String(format: "%.1f", seconds)) s = \(String(format: "%.1f", Double(batch.count) / seconds)) docs/s")
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).map(*).reduce(0, +)
        return dot / (sqrt(a.map { $0 * $0 }.reduce(0, +)) * sqrt(b.map { $0 * $0 }.reduce(0, +)))
    }

    private func argmax(_ docs: [[Float]], _ query: [Float]) -> Int {
        docs.indices.max { cosine(docs[$0], query) < cosine(docs[$1], query) }!
    }
}
