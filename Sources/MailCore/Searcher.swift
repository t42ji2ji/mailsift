import Accelerate
import Foundation

/// Hybrid search: brute-force cosine over all stored vectors plus FTS5 keyword search, merged by reciprocal rank
/// fusion. Messages without vectors yet are still found by keyword.
final class Searcher: @unchecked Sendable {
    static let candidates = 100
    static let rrfK = 60.0

    private let store: IndexStore
    private let lock = NSLock()
    // Row-major [ids.count × dimension] copy of the vectors table, loaded once and extended as vectors are added.
    private var matrix: [Float] = []
    private var ids: [Int64] = []
    private var lastSeq: Int64 = 0

    init(store: IndexStore) { self.store = store }

    /// Drops the in-memory vectors; call after deleting messages.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        matrix = []
        ids = []
        lastSeq = 0
    }

    func search(_ query: String, filter: SearchFilter, limit: Int, embedder: TextEmbedder?) async throws -> [SearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }

        // Trigram FTS only matches terms of 3+ characters. Shorter terms (e.g. two-character Chinese words) fall
        // back to a substring scan, used only when the query has no longer term to search for.
        let long = terms.filter { $0.count >= 3 }
        let keyword = long.isEmpty
            ? try store.substringSearch(terms, filter: filter, limit: Self.candidates)
            : try store.fullTextSearch(long, filter: filter, limit: Self.candidates)

        var semantic: [Int64] = []
        if let embedder {
            let vector = try await embedder.embedQuery(query)
            semantic = try nearest(vector, allowed: try store.ids(matching: filter), limit: Self.candidates)
        }

        var scores: [Int64: Double] = [:]
        for (rank, id) in keyword.enumerated() { scores[id, default: 0] += 1 / (Self.rrfK + Double(rank + 1)) }
        for (rank, id) in semantic.enumerated() { scores[id, default: 0] += 1 / (Self.rrfK + Double(rank + 1)) }
        let keywordSet = Set(keyword)
        let semanticSet = Set(semantic)
        let ranked = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }.prefix(limit)

        let rows = try store.metaAndBody(ranked.map(\.key))
        return ranked.compactMap { id, score in
            guard let row = rows[id] else { return nil }
            let inKeyword = keywordSet.contains(id)
            let match: SearchHit.Match = inKeyword && semanticSet.contains(id) ? .both : inKeyword ? .keyword : .semantic
            return SearchHit(meta: row.meta, snippet: Self.snippet(row.body, terms: inKeyword ? terms : []),
                             score: score, match: match)
        }
    }

    /// Ids of the `limit` stored vectors closest to `query` (dot product of normalized vectors), best first.
    func nearest(_ query: [Float], allowed: Set<Int64>?, limit: Int) throws -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        try refresh()
        let rows = ids.count
        guard rows > 0, matrix.count == rows * query.count else { return [] }
        var scores = [Float](repeating: 0, count: rows)
        vDSP_mmul(matrix, 1, query, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(query.count))
        // Keep the best `limit` in a small sorted buffer: one pass, no full sort of all rows.
        var best: [(score: Float, row: Int)] = []
        best.reserveCapacity(limit + 1)
        for row in 0..<rows {
            let score = scores[row]
            if best.count == limit, score <= best[limit - 1].score { continue }
            if let allowed, !allowed.contains(ids[row]) { continue }
            let index = best.firstIndex { $0.score < score } ?? best.count
            best.insert((score, row), at: index)
            if best.count > limit { best.removeLast() }
        }
        return best.map { ids[$0.row] }
    }

    /// Loads vectors added since the last call; reloads everything when some were deleted. Caller holds `lock`.
    private func refresh() throws {
        let state = try store.vectorState()
        if state.maxSeq > lastSeq {
            lastSeq = try store.vectors(after: lastSeq, upTo: state.maxSeq, into: &matrix, ids: &ids)
        }
        if ids.count != state.count {
            matrix = []
            ids = []
            lastSeq = try store.vectors(after: 0, upTo: .max, into: &matrix, ids: &ids)
        }
    }

    /// Text around the first occurrence of any term, else the start of the body.
    static func snippet(_ body: String, terms: [String], length: Int = 160) -> String {
        let text = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let hit = terms.lazy.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let hit else { return String(text.prefix(length)) }
        let start = text.index(hit.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let snippet = String(text[start...].prefix(length))
        return start == text.startIndex ? snippet : "…" + snippet
    }
}
