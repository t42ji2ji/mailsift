import XCTest
@testable import MailCore

final class SenderMapTests: XCTestCase {
    func testKMeansSeparatesObviousGroups() {
        // Two tight groups on orthogonal axes.
        let rows: [[Float]] = [[1, 0, 0], [0.99, 0.1, 0], [0.98, 0, 0.1], [0, 1, 0], [0.1, 0.99, 0], [0, 0.98, 0.1]]
        let x = rows.flatMap { r in r.map { $0 / sqrt(r.reduce(0) { $0 + $1 * $1 }) } }
        let labels = KMeans.cluster(x, n: 6, dim: 3, k: 2)
        XCTAssertEqual(Set(labels[0..<3]).count, 1)
        XCTAssertEqual(Set(labels[3..<6]).count, 1)
        XCTAssertNotEqual(labels[0], labels[3])
    }

    func testTSNEKeepsGroupsApart() {
        var rows: [[Float]] = []
        var rng = SplitMix(seed: 1)
        for axis in 0..<3 {
            for _ in 0..<20 {
                var v = [Float](repeating: 0, count: 8)
                v[axis] = 1
                for k in 0..<8 { v[k] += Float(rng.nextDouble() * 0.1) }
                let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
                rows.append(v.map { $0 / norm })
            }
        }
        let y = TSNE.embed(rows.flatMap { $0 }, n: 60, dim: 8, perplexity: 10, iterations: 400)
        func centroid(_ g: Int) -> (Double, Double) {
            let pts = y[(g * 20)..<((g + 1) * 20)]
            return (pts.map(\.0).reduce(0, +) / 20, pts.map(\.1).reduce(0, +) / 20)
        }
        func spread(_ g: Int) -> Double {
            let c = centroid(g)
            return y[(g * 20)..<((g + 1) * 20)].map { hypot($0.0 - c.0, $0.1 - c.1) }.reduce(0, +) / 20
        }
        let between = hypot(centroid(0).0 - centroid(1).0, centroid(0).1 - centroid(1).1)
        XCTAssertGreaterThan(between, 2 * max(spread(0), spread(1)))
    }

    /// Timing on the real index; skipped unless MAILSIFT_REAL=1.
    func testRealSenderMapTiming() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILSIFT_REAL"] == "1")
        let lib = try MailLibrary(source: AppleMailSource(), embedder: nil)
        let start = Date()
        let map = lib.senderMap()
        print("sender map: \(map.points.count) senders, \(map.clusters.count) clusters in \(Date().timeIntervalSince(start))s")
        for c in map.clusters { print("  \(c.messages) msgs:", c.topSenders.joined(separator: " / ")) }
    }
}
