import Accelerate
import Foundation
import NaturalLanguage

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
    private var rowOf: [Int64: Int] = [:]
    private var lastSeq: Int64 = 0

    init(store: IndexStore) { self.store = store }

    /// Drops the in-memory vectors; call after deleting messages.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        matrix = []
        ids = []
        rowOf = [:]
        lastSeq = 0
    }

    func search(_ query: String, filter: SearchFilter, limit: Int, embedder: TextEmbedder?) async throws -> [SearchHit] {
        let terms = SearchTerms.of(query)
        guard !terms.isEmpty else { return [] }
        let keyword = try store.keywordSearch(terms, filter: filter, limit: Self.candidates)

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
            return SearchHit(meta: row.meta, snippet: Self.snippet(row.body, terms: terms),
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

    /// Scores of every stored vector against each of `queries`: row-major [ids.count × queries.count].
    func scores(_ queries: [[Float]]) throws -> (ids: [Int64], scores: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        try refresh()
        let rows = ids.count, k = queries.count
        guard rows > 0, let dim = queries.first?.count, matrix.count == rows * dim else { return ([], []) }
        // [dim × k], so one multiply scores every message against every query.
        var columns = [Float](repeating: 0, count: dim * k)
        for (j, q) in queries.enumerated() { for t in 0..<dim { columns[t * k + j] = q[t] } }
        var out = [Float](repeating: 0, count: rows * k)
        vDSP_mmul(matrix, 1, columns, 1, &out, 1, vDSP_Length(rows), vDSP_Length(k), vDSP_Length(dim))
        return (ids, out)
    }

    /// Normalized mean of the stored vectors of `members`.
    func mean(_ members: [Int64]) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        try refresh()
        let wanted = Set(members)
        let dim = ids.isEmpty ? 0 : matrix.count / ids.count
        var sum = [Float](repeating: 0, count: dim)
        for (row, id) in ids.enumerated() where wanted.contains(id) {
            for t in 0..<dim { sum[t] += matrix[row * dim + t] }
        }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? sum.map { $0 / norm } : sum
    }

    /// Loads vectors added since the last call, a re-embedded message replacing its row; reloads everything when
    /// some were deleted. Caller holds `lock`.
    private func refresh() throws {
        let state = try store.vectorState()
        if state.maxSeq > lastSeq {
            var added: [Float] = [], addedIDs: [Int64] = []
            lastSeq = try store.vectors(after: lastSeq, upTo: state.maxSeq, into: &added, ids: &addedIDs)
            let dim = addedIDs.isEmpty ? 0 : added.count / addedIDs.count
            for (k, id) in addedIDs.enumerated() {
                let vector = added[k * dim..<(k + 1) * dim]
                if let row = rowOf[id] {
                    matrix.replaceSubrange(row * dim..<(row + 1) * dim, with: vector)
                } else {
                    rowOf[id] = ids.count
                    ids.append(id)
                    matrix.append(contentsOf: vector)
                }
            }
        }
        if ids.count != state.count {
            matrix = []
            ids = []
            lastSeq = try store.vectors(after: 0, upTo: .max, into: &matrix, ids: &ids)
            rowOf = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        }
    }

    /// `text` with web and mailto links blanked out: in mail converted from HTML they are about a third of the text.
    static func withoutLinks(_ text: String) -> String {
        text.replacingOccurrences(of: #"<?\b(https?://|mailto:)[^\s>]*>?"#, with: " ", options: .regularExpression)
    }

    /// Text around the first occurrence of any term, else the start of the body. Links are left out.
    static func snippet(_ body: String, terms: [String], length: Int = 160) -> String {
        let text = withoutLinks(body).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let hit = terms.lazy.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let hit else { return String(text.prefix(length)) }
        let start = text.index(hit.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let snippet = String(text[start...].prefix(length))
        return start == text.startIndex ? snippet : "…" + snippet
    }
}

/// The words of a query, for keyword search and highlighting. Spaces separate words; text in Chinese or Japanese is
/// segmented further. The segmenter splits words it doesn't know into characters (訂位 → 訂 位), so runs of single
/// characters are joined back. Particles and short English function words are dropped when other words remain.
public enum SearchTerms {
    private static let fillers: Set<String> = [
        "的", "了", "在", "是", "和", "與", "及", "或", "跟", "把", "被", "嗎", "呢", "吧", "a", "an", "the", "to", "for",
        "of", "in", "on", "at", "and", "or", "with", "from", "by", "is", "my", "me", "i",
    ]

    public static func of(_ query: String) -> [String] {
        var terms: [String] = []
        for word in query.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard word.unicodeScalars.contains(where: isCJK) else { terms.append(word); continue }
            let before = terms.count
            var run = ""
            func flush() { if !run.isEmpty { terms.append(run); run = "" } }
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = word
            tokenizer.enumerateTokens(in: word.startIndex..<word.endIndex) { range, _ in
                let token = String(word[range])
                if fillers.contains(token) {
                    flush()
                } else if token.count == 1, token.unicodeScalars.allSatisfy(isCJK) {
                    run += token
                } else {
                    flush()
                    terms.append(token)
                }
                return true
            }
            flush()
            if terms.count == before { terms.append(word) }
        }
        var seen = Set<String>()
        terms = terms.filter { seen.insert($0.lowercased()).inserted }
        let kept = terms.filter { !fillers.contains($0.lowercased()) && !($0.count == 1 && $0.unicodeScalars.allSatisfy(isCJK)) }
        return kept.isEmpty ? terms : kept
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}
