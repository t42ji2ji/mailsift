import Foundation
import XCTest
@testable import MailCore

/// Compares the Swift parser with mail.db from the earlier Python prototype (private mail; skipped elsewhere).
/// Set MAILSIFT_GOLDEN_DUMP=<file> to write per-message mismatch details for investigation.
final class AppleMailGoldenTests: XCTestCase {
    static let goldenDB = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("me/mail-search/mail.db").path

    func testParserAgreesWithPythonPrototype() throws {
        guard FileManager.default.fileExists(atPath: Self.goldenDB) else { throw XCTSkip("no golden mail.db") }
        let db = try ReadOnlySQLite(path: Self.goldenDB)
        var rows: [(id: Int64, path: String, subject: String, sender: String, body: String)] = []
        let limit = Int(ProcessInfo.processInfo.environment["MAILSIFT_GOLDEN_LIMIT"] ?? "") ?? 500
        let mod = Int(ProcessInfo.processInfo.environment["MAILSIFT_GOLDEN_MOD"] ?? "") ?? 57
        try db.query("select id, path, subject, sender, body from mail where id % ? = 0 order by id limit ?", [mod, limit]) { r in
            rows.append((r.int(0), r.text(1) ?? "", r.text(2) ?? "", r.text(3) ?? "", r.text(4) ?? ""))
        }
        XCTAssertGreaterThan(rows.count, 100)

        let files = try AppleMailSource().messageFiles()
        var n = 0, subjRaw = 0, subjNorm = 0, sender = 0, bodyExact = 0, bodyClose = 0, pathSame = 0
        var simSum = 0.0
        var dump = ""
        var inexact = ""
        for row in rows {
            guard let p = try AppleMailSource.parseFile(path: row.path) else { continue }
            n += 1
            if files[row.id] == row.path { pathSame += 1 }
            let sOK = Self.collapse(p.subject) == Self.collapse(row.subject)
            if p.subject == row.subject { subjRaw += 1 }
            if sOK { subjNorm += 1 }
            let pyAddr = Self.addressIn(row.sender)
            let fOK = (p.from?.address.lowercased() ?? "") == pyAddr
            if fOK { sender += 1 }
            let a = Self.squash(p.bodyText), b = Self.squash(row.body)
            let sim = a == b ? 1 : Self.trigramJaccard(a, b)
            simSum += sim
            if a == b { bodyExact += 1 } else if let obj = try? JSONSerialization.data(withJSONObject: ["id": row.id, "swift": a, "py": b]) {
                inexact += String(decoding: obj, as: UTF8.self) + "\n"
            }
            if sim >= 0.9 { bodyClose += 1 }
            if !sOK || !fOK || sim < 0.9 {
                dump += "\(row.id)\tsubj=\(sOK)\tfrom=\(fOK)\tsim=\(String(format: "%.2f", sim))\tlen=\(a.count)/\(b.count)\n"
                if !sOK { dump += "  S swift: \(p.subject)\n  S py:    \(row.subject)\n" }
                if !fOK { dump += "  F swift: \(p.from?.address ?? "-")\n  F py:    \(row.sender)\n" }
                if sim < 0.9 { dump += "  B swift: \(a.prefix(300))\n  B py:    \(b.prefix(300))\n" }
            }
        }
        let pct = { (k: Int) in String(format: "%.1f%%", 100 * Double(k) / Double(max(n, 1))) }
        print("""
            golden n=\(n) subject raw=\(pct(subjRaw)) normalized=\(pct(subjNorm)) sender=\(pct(sender)) \
            body exact=\(pct(bodyExact)) sim>=0.9=\(pct(bodyClose)) meanSim=\(String(format: "%.3f", simSum / Double(max(n, 1)))) \
            pathMap=\(pct(pathSame))
            """)
        if let out = ProcessInfo.processInfo.environment["MAILSIFT_GOLDEN_DUMP"] {
            try dump.write(toFile: out, atomically: true, encoding: .utf8)
            try inexact.write(toFile: out + ".inexact.jsonl", atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThanOrEqual(Double(subjNorm) / Double(n), 0.98)
        XCTAssertGreaterThanOrEqual(Double(sender) / Double(n), 0.98)
        XCTAssertGreaterThanOrEqual(Double(bodyClose) / Double(n), 0.95)
    }

    static func collapse(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    /// Drops whitespace and the invisible padding characters the Swift side strips on purpose.
    static func squash(_ s: String) -> String {
        var v = String.UnicodeScalarView()
        for u in s.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(u) {
            switch u.value {
            case 0x00...0x1F, 0x7F, 0xAD, 0x034F, 0x200B, 0x200C, 0x2060, 0xFEFF: continue
            default: v.append(u)
            }
        }
        return String(v)
    }

    static func addressIn(_ from: String) -> String {
        if let lt = from.lastIndex(of: "<"), let gt = from[lt...].firstIndex(of: ">") {
            return from[from.index(after: lt)..<gt].lowercased()
        }
        return from.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func trigramJaccard(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> Set<String> {
            let c = Array(s)
            guard c.count >= 3 else { return [s] }
            return Set((0...(c.count - 3)).map { String(c[$0..<$0 + 3]) })
        }
        let ga = grams(a), gb = grams(b)
        let u = ga.union(gb).count
        return u == 0 ? 1 : Double(ga.intersection(gb).count) / Double(u)
    }
}

/// Dev aid: MAILSIFT_DEBUG_PATH=<emlx> MAILSIFT_DEBUG_OUT=<file> writes the parsed body for inspection.
final class AppleMailDebugParseTests: XCTestCase {
    func testDebugParse() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MAILSIFT_DEBUG_PATH"], let out = env["MAILSIFT_DEBUG_OUT"] else { throw XCTSkip("dev only") }
        let p = try XCTUnwrap(try AppleMailSource.parseFile(path: path))
        try (p.subject + "\n---\n" + p.bodyText).write(toFile: out, atomically: true, encoding: .utf8)
    }
}
