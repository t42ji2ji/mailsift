import Foundation

/// A 2-D map of senders: each sender's mean embedding, laid out with t-SNE so senders who write similar mail sit
/// together, and grouped with k-means (on the embeddings, not the layout) into labelled regions.
public struct SenderMap: Sendable {
    public struct Point: Sendable, Identifiable {
        public var stat: SenderStat
        public var x: Double   // 0…1
        public var y: Double   // 0…1
        public var cluster: Int
        public var id: String { stat.id }
    }

    public struct Cluster: Sendable, Identifiable {
        public var id: Int
        /// Display names of the largest senders, biggest first.
        public var topSenders: [String]
        public var senders: Int
        public var messages: Int
        public var x: Double
        public var y: Double
    }

    public var points: [Point]
    public var clusters: [Cluster]
}

extension MailLibrary {
    /// Senders with at least `minCount` embedded messages. Takes a few seconds for ~1,500 senders.
    public func senderMap(minCount: Int = 3, clusterCount: Int = 12) -> SenderMap {
        guard let groups = try? store.senderCentroids(minCount: minCount), groups.count >= 3 else {
            return SenderMap(points: [], clusters: [])
        }
        let stats = Dictionary(senders(limit: 1_000_000).map { ($0.account + "|" + $0.address.lowercased(), $0) },
                               uniquingKeysWith: { a, _ in a })
        let dim = groups[0].sum.count
        var rows: [SenderStat] = []
        var x: [Float] = []
        for g in groups {
            guard let stat = stats[g.account + "|" + g.address] else { continue }
            let norm = sqrt(g.sum.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { continue }
            rows.append(stat)
            x += g.sum.map { $0 / norm }
        }
        let n = rows.count
        guard n >= 3 else { return SenderMap(points: [], clusters: []) }

        let layout = TSNE.embed(x, n: n, dim: dim)
        let labels = KMeans.cluster(x, n: n, dim: dim, k: min(clusterCount, n))

        // Normalize to 0…1 with a small margin.
        let xs = layout.map(\.0), ys = layout.map(\.1)
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        let span = max(maxX - minX, maxY - minY, 1e-6)
        let points = (0..<n).map { i in
            SenderMap.Point(stat: rows[i], x: 0.04 + 0.92 * (xs[i] - minX) / span, y: 0.04 + 0.92 * (ys[i] - minY) / span,
                  cluster: labels[i])
        }
        let clusters = Dictionary(grouping: points, by: \.cluster).map { id, members in
            let byCount = members.sorted { $0.stat.count > $1.stat.count }
            let weight = Double(members.reduce(0) { $0 + $1.stat.count })
            return SenderMap.Cluster(
                id: id,
                topSenders: byCount.prefix(3).map { $0.stat.name.isEmpty ? $0.stat.address : $0.stat.name },
                senders: members.count, messages: Int(weight),
                // Weighted toward big senders, so the label sits where the mail actually is.
                x: members.reduce(0) { $0 + $1.x * Double($1.stat.count) } / weight,
                y: members.reduce(0) { $0 + $1.y * Double($1.stat.count) } / weight)
        }
        return SenderMap(points: points, clusters: clusters.sorted { $0.messages > $1.messages })
    }
}

/// Exact t-SNE (O(n²) per iteration; fine for a few thousand points) on L2-normalized rows, cosine distance.
enum TSNE {
    static func embed(_ x: [Float], n: Int, dim: Int, perplexity: Double = 30, iterations: Int = 750) -> [(Double, Double)] {
        // Squared-ish distance: cosine distance on unit vectors.
        var d = [Double](repeating: 0, count: n * n)
        x.withUnsafeBufferPointer { v in
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var dot: Float = 0
                    for k in 0..<dim { dot += v[i * dim + k] * v[j * dim + k] }
                    let dist = Double(max(0, 1 - dot))
                    d[i * n + j] = dist
                    d[j * n + i] = dist
                }
            }
        }

        // Conditional probabilities with a per-point bandwidth matching the perplexity.
        var p = [Double](repeating: 0, count: n * n)
        let target = log(min(perplexity, Double(n - 1) / 3))
        for i in 0..<n {
            var beta = 1.0, lo = 0.0, hi = Double.infinity
            for _ in 0..<60 {
                var sum = 0.0, weighted = 0.0
                for j in 0..<n where j != i {
                    let e = exp(-d[i * n + j] * beta)
                    p[i * n + j] = e
                    sum += e
                    weighted += d[i * n + j] * e
                }
                sum = max(sum, 1e-12)
                let entropy = log(sum) + beta * weighted / sum
                for j in 0..<n where j != i { p[i * n + j] /= sum }
                if abs(entropy - target) < 1e-5 { break }
                if entropy > target {
                    lo = beta
                    beta = hi.isInfinite ? beta * 2 : (beta + hi) / 2
                } else {
                    hi = beta
                    beta = (beta + lo) / 2
                }
            }
        }
        // Symmetrize.
        for i in 0..<n {
            for j in (i + 1)..<n {
                let v = max((p[i * n + j] + p[j * n + i]) / Double(2 * n), 1e-12)
                p[i * n + j] = v
                p[j * n + i] = v
            }
        }

        // Deterministic small initial layout.
        var rng = SplitMix(seed: 42)
        var y = (0..<(2 * n)).map { _ in (rng.nextDouble() - 0.5) * 1e-2 }
        var velocity = [Double](repeating: 0, count: 2 * n)
        var gains = [Double](repeating: 1, count: 2 * n)
        var num = [Double](repeating: 0, count: n * n)
        let rate = max(Double(n) / 12, 50)

        for iter in 0..<iterations {
            let exaggeration = iter < 250 ? 12.0 : 1.0
            let momentum = iter < 250 ? 0.5 : 0.8
            var qSum = 0.0
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = y[2 * i] - y[2 * j], dy = y[2 * i + 1] - y[2 * j + 1]
                    let q = 1 / (1 + dx * dx + dy * dy)
                    num[i * n + j] = q
                    num[j * n + i] = q
                    qSum += 2 * q
                }
            }
            // All gradients from the same positions, then one update.
            var grad = [Double](repeating: 0, count: 2 * n)
            for i in 0..<n {
                var gx = 0.0, gy = 0.0
                for j in 0..<n where j != i {
                    let q = num[i * n + j]
                    let f = (exaggeration * p[i * n + j] - q / qSum) * q
                    gx += f * (y[2 * i] - y[2 * j])
                    gy += f * (y[2 * i + 1] - y[2 * j + 1])
                }
                grad[2 * i] = 4 * gx
                grad[2 * i + 1] = 4 * gy
            }
            for k in 0..<(2 * n) {
                let g = grad[k]
                gains[k] = (g > 0) != (velocity[k] > 0) ? gains[k] + 0.2 : max(gains[k] * 0.8, 0.01)
                velocity[k] = momentum * velocity[k] - rate * gains[k] * g
                y[k] += velocity[k]
            }
        }
        return (0..<n).map { (y[2 * $0], y[2 * $0 + 1]) }
    }
}

/// k-means++ with cosine similarity on unit vectors; deterministic.
enum KMeans {
    static func cluster(_ x: [Float], n: Int, dim: Int, k: Int, iterations: Int = 25) -> [Int] {
        var rng = SplitMix(seed: 7)
        func dot(_ a: Int, _ c: [Float]) -> Float {
            var s: Float = 0
            for t in 0..<dim { s += x[a * dim + t] * c[t] }
            return s
        }
        var centers = [Array(x[0..<dim])]
        while centers.count < k {
            let far = (0..<n).map { i in Double(max(0, 1 - centers.map { dot(i, $0) }.max()!)) }
            var pick = rng.nextDouble() * far.reduce(0, +)
            var chosen = n - 1
            for i in 0..<n {
                pick -= far[i]
                if pick <= 0 { chosen = i; break }
            }
            centers.append(Array(x[(chosen * dim)..<((chosen + 1) * dim)]))
        }
        var labels = [Int](repeating: 0, count: n)
        for _ in 0..<iterations {
            for i in 0..<n {
                var best = 0
                var bestSim = -Float.infinity
                for (c, center) in centers.enumerated() {
                    let s = dot(i, center)
                    if s > bestSim { bestSim = s; best = c }
                }
                labels[i] = best
            }
            for c in 0..<k {
                var sum = [Float](repeating: 0, count: dim)
                var members = 0
                for i in 0..<n where labels[i] == c {
                    for t in 0..<dim { sum[t] += x[i * dim + t] }
                    members += 1
                }
                guard members > 0 else { continue }
                let norm = max(sqrt(sum.reduce(0) { $0 + $1 * $1 }), 1e-9)
                centers[c] = sum.map { $0 / norm }
            }
        }
        return labels
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
