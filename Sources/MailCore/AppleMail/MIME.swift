import Foundation

/// One MIME entity: headers plus either leaf body bytes (still transfer-encoded) or child parts.
struct MIMEPart {
    var headers: [(name: String, value: String)]   // name lowercased, value unfolded but not RFC 2047-decoded
    var body: ArraySlice<UInt8>
    var rawHeaders: ArraySlice<UInt8> = []
    var children: [MIMEPart] = []

    func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }

    var contentType: (type: String, params: [String: String]) {
        MIME.parseParameterized(header("content-type") ?? "text/plain")
    }
    var mimeType: String { contentType.type.isEmpty ? "text/plain" : contentType.type }

    var isAttachment: Bool {
        let disp = MIME.parseParameterized(header("content-disposition") ?? "")
        if disp.type == "attachment" { return true }
        if disp.params["filename"] != nil { return true }
        return contentType.params["name"] != nil
    }

    /// Body with Content-Transfer-Encoding undone.
    var decodedBody: [UInt8] {
        switch (header("content-transfer-encoding") ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        // Some senders label raw 8-bit text as base64; real base64 never has bytes ≥ 0x80.
        case "base64": return body.contains(where: { $0 >= 0x80 }) ? Array(body) : MIME.decodeBase64(body)
        case "quoted-printable": return MIME.decodeQuotedPrintable(body, header: false)
        default: return Array(body)
        }
    }

    /// Decoded text with line endings normalized to "\n" (a "\r\n" is one Character and defeats line splitting).
    var text: String {
        Charsets.decode(decodedBody, charset: contentType.params["charset"])
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Depth-first leaves.
    func leaves() -> [MIMEPart] { children.isEmpty ? [self] : children.flatMap { $0.leaves() } }
}

enum MIME {
    // MARK: Entity parsing

    /// Parses an RFC 822 message. Line endings are normalized to LF first.
    static func parse(_ raw: some Collection<UInt8>) -> MIMEPart {
        var bytes = [UInt8]()
        bytes.reserveCapacity(raw.count)
        var prevCR = false
        for b in raw {
            if prevCR && b != 0x0A { bytes.append(0x0A) }
            prevCR = b == 0x0D
            if !prevCR { bytes.append(b) }
        }
        if prevCR { bytes.append(0x0A) }
        var root = parseEntity(bytes[...], depth: 0)
        // Raw 8-bit headers that aren't UTF-8 are usually in the body's charset.
        if root.rawHeaders.contains(where: { $0 >= 0x80 }), String(bytes: root.rawHeaders, encoding: .utf8) == nil,
           let cs = root.leaves().lazy.compactMap({ $0.contentType.params["charset"] }).first {
            root.headers = parseHeaders(root.rawHeaders, charset: cs)
        }
        return root
    }

    private static func parseEntity(_ bytes: ArraySlice<UInt8>, depth: Int) -> MIMEPart {
        // The header block ends at the first empty line, or at the first line that is neither a header field nor a
        // continuation (some senders put the multipart boundary straight after the headers).
        var headerEnd = bytes.endIndex
        var bodyStart = bytes.endIndex
        var lineStart = bytes.startIndex
        while lineStart < bytes.endIndex {
            let lineEnd = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.endIndex
            let line = bytes[lineStart..<lineEnd]
            if line.isEmpty {
                headerEnd = lineStart; bodyStart = min(lineEnd + 1, bytes.endIndex); break
            }
            if !isHeaderLine(line, first: lineStart == bytes.startIndex) {
                headerEnd = lineStart; bodyStart = lineStart; break
            }
            lineStart = lineEnd < bytes.endIndex ? lineEnd + 1 : bytes.endIndex
        }
        let headers = parseHeaders(bytes[bytes.startIndex..<headerEnd])
        var part = MIMEPart(headers: headers, body: bytes[bodyStart..<bytes.endIndex], rawHeaders: bytes[bytes.startIndex..<headerEnd])
        let ct = part.contentType
        if ct.type.hasPrefix("multipart/"), let boundary = ct.params["boundary"], !boundary.isEmpty, depth < 20 {
            part.children = splitMultipart(part.body, boundary: boundary).map { parseEntity($0, depth: depth + 1) }
        }
        return part
    }

    /// "Name: value" (field name of printable ASCII without spaces) or, after the first line, a folded continuation.
    private static func isHeaderLine(_ line: ArraySlice<UInt8>, first: Bool) -> Bool {
        if let f = line.first, f == 0x20 || f == 0x09 { return !first }
        for b in line {
            if b == 0x3A { return true }
            if b <= 0x20 || b >= 0x7F { return false }
        }
        return false
    }

    static func parseHeaders(_ block: ArraySlice<UInt8>, charset: String? = nil) -> [(name: String, value: String)] {
        let text = Charsets.decode(block, charset: charset)
        var out: [(String, String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = line.first, f == " " || f == "\t" {
                if !out.isEmpty { out[out.count - 1].1 += line }   // unfold: drop the newline, keep the WSP
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { continue }
            out.append((name, String(line[line.index(after: colon)...])))
        }
        return out.map { ($0.0, $0.1.trimmingCharacters(in: .whitespaces)) }
    }

    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delim = Array(("--" + boundary).utf8)
        var parts: [ArraySlice<UInt8>] = []
        var current: Int? = nil       // start of the current part's bytes
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(of: 0x0A) ?? body.endIndex
            let line = body[lineStart..<lineEnd]
            if line.count >= delim.count, line.starts(with: delim) {
                var rest = line.dropFirst(delim.count)
                let closing = rest.starts(with: [0x2D, 0x2D])
                if closing { rest = rest.dropFirst(2) }
                if rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    if let s = current {
                        // The newline before the delimiter belongs to the delimiter.
                        var e = lineStart
                        if e > s, body[body.index(before: e)] == 0x0A { e = body.index(before: e) }
                        parts.append(body[s..<max(s, e)])
                    }
                    if closing { return parts }
                    current = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
                }
            }
            lineStart = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
        }
        if let s = current, s < body.endIndex { parts.append(body[s..<body.endIndex]) }   // unterminated
        return parts
    }

    /// `text/plain; charset="big5"; name*=utf-8''%E4%B8%AD` → ("text/plain", ["charset": "big5", "name": "中"]).
    static func parseParameterized(_ value: String) -> (type: String, params: [String: String]) {
        var segments: [String] = []
        var cur = ""
        var inQuote = false
        var escape = false
        for c in value {
            if escape { cur.append(c); escape = false; continue }
            if inQuote && c == "\\" { escape = true; continue }
            if c == "\"" { inQuote.toggle(); continue }
            if c == ";" && !inQuote { segments.append(cur); cur = ""; continue }
            cur.append(c)
        }
        segments.append(cur)
        let type = segments[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var params: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]
        for seg in segments.dropFirst() {
            guard let eq = seg.firstIndex(of: "=") else { continue }
            var key = seg[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = seg[seg.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            // RFC 2231: key*=charset'lang'pct-encoded, key*0*=…, key*1=…
            var extended = false
            if key.hasSuffix("*") { extended = true; key.removeLast() }
            if let star = key.firstIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                continuations[String(key[..<star]), default: []].append((n, val, extended))
                continue
            }
            params[key] = extended ? decode2231(val) : val
        }
        for (key, pieces) in continuations where params[key] == nil {
            let sorted = pieces.sorted { $0.0 < $1.0 }
            if sorted.contains(where: { $0.2 }) {
                params[key] = decode2231(sorted.map(\.1).joined())
            } else {
                params[key] = sorted.map(\.1).joined()
            }
        }
        return (type, params)
    }

    private static func decode2231(_ v: String) -> String {
        let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return v.removingPercentEncoding ?? v }
        var bytes: [UInt8] = []
        var it = Array(parts[2].utf8)[...]
        while let b = it.popFirst() {
            if b == 0x25, it.count >= 2, let h = hex(it[it.startIndex]), let l = hex(it[it.startIndex + 1]) {
                bytes.append(h << 4 | l); it = it.dropFirst(2)
            } else { bytes.append(b) }
        }
        return Charsets.decode(bytes, charset: String(parts[0]))
    }

    // MARK: Transfer encodings

    static func decodeBase64(_ body: some Collection<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(body.count * 3 / 4)
        var acc: UInt32 = 0
        var n = 0
        for c in body {
            let v: UInt32
            switch c {
            case 0x41...0x5A: v = UInt32(c - 0x41)
            case 0x61...0x7A: v = UInt32(c - 0x61 + 26)
            case 0x30...0x39: v = UInt32(c - 0x30 + 52)
            case 0x2B, 0x2D: v = 62
            case 0x2F, 0x5F: v = 63
            case 0x3D:   // padding ends a quantum
                if n == 2 { out.append(UInt8(acc >> 4 & 0xFF)) }
                if n == 3 { out.append(UInt8(acc >> 10 & 0xFF)); out.append(UInt8(acc >> 2 & 0xFF)) }
                n = 0; acc = 0; continue
            default: continue
            }
            acc = acc << 6 | v
            n += 1
            if n == 4 {
                out.append(UInt8(acc >> 16 & 0xFF)); out.append(UInt8(acc >> 8 & 0xFF)); out.append(UInt8(acc & 0xFF))
                acc = 0; n = 0
            }
        }
        if n == 2 { out.append(UInt8(acc >> 4 & 0xFF)) }
        if n == 3 { out.append(UInt8(acc >> 10 & 0xFF)); out.append(UInt8(acc >> 2 & 0xFF)) }
        return out
    }

    /// Quoted-printable; `header` turns "_" into space (RFC 2047 Q).
    static func decodeQuotedPrintable(_ body: some Collection<UInt8>, header: Bool) -> [UInt8] {
        let a = Array(body)
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var i = 0
        while i < a.count {
            let c = a[i]
            if c == 0x3D {
                if i + 2 < a.count, let h = hex(a[i + 1]), let l = hex(a[i + 2]) {
                    out.append(h << 4 | l); i += 3; continue
                }
                // soft line break: "=" followed by optional whitespace then newline
                var j = i + 1
                while j < a.count, a[j] == 0x20 || a[j] == 0x09 { j += 1 }
                if j < a.count, a[j] == 0x0A { i = j + 1; continue }
                if j >= a.count { i = j; continue }
                out.append(c); i += 1; continue
            }
            if header && c == 0x5F { out.append(0x20); i += 1; continue }
            out.append(c); i += 1
        }
        return out
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    // MARK: RFC 2047

    /// Decodes encoded words. Whitespace between adjacent encoded words is dropped, and adjacent words in the
    /// same charset are joined before decoding so multibyte characters split across words survive.
    static func decodeHeader(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let s = Array(value.unicodeScalars)
        var out = ""
        var pending: (charset: String, bytes: [UInt8])? = nil
        var gap = ""          // whitespace seen after an encoded word, emitted only if plain text follows
        var i = 0
        func flush() {
            if let p = pending { out += Charsets.decode(p.bytes, charset: p.charset) }
            pending = nil
        }
        while i < s.count {
            if s[i] == "=", i + 1 < s.count, s[i + 1] == "?", let (charset, bytes, end) = encodedWord(s, at: i) {
                if let p = pending, p.charset.lowercased() == charset.lowercased() {
                    pending!.bytes += bytes
                } else {
                    flush()
                    pending = (charset, bytes)
                }
                gap = ""
                i = end
                // swallow whitespace; keep it in case plain text follows
                while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r" { gap.unicodeScalars.append(s[i]); i += 1 }
                continue
            }
            flush()
            out += gap; gap = ""
            out.unicodeScalars.append(s[i])
            i += 1
        }
        flush()
        out += gap
        return out
    }

    /// Recognizes `=?charset?B|Q?text?=` at `i`; returns raw bytes and the index after "?=".
    private static func encodedWord(_ s: [Unicode.Scalar], at i: Int) -> (String, [UInt8], Int)? {
        var j = i + 2
        var charset = ""
        while j < s.count, s[j] != "?" {
            if s[j] == " " || s[j] == "\n" { return nil }
            charset.unicodeScalars.append(s[j]); j += 1
        }
        guard j + 2 < s.count, !charset.isEmpty, s[j + 2] == "?" else { return nil }
        let enc = s[j + 1]
        guard enc == "B" || enc == "b" || enc == "Q" || enc == "q" else { return nil }
        var k = j + 3
        var text: [UInt8] = []
        let isB = enc == "B" || enc == "b"
        while k + 1 < s.count, !(s[k] == "?" && s[k + 1] == "=") {
            let c = s[k]
            guard c.isASCII else { return nil }
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                // Some senders fold inside a B word; base64 can skip the whitespace. In Q it ends the word.
                guard isB else { return nil }
                k += 1; continue
            }
            if isB, !(c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "+" || c == "/" || c == "=") { return nil }
            text.append(UInt8(c.value)); k += 1
        }
        guard k + 1 < s.count else { return nil }
        let bytes = isB ? decodeBase64(text) : decodeQuotedPrintable(text, header: true)
        return (charset, bytes, k + 2)
    }

    // MARK: Addresses

    struct Address: Equatable { var name: String; var address: String }

    /// Parses an address-list header (raw, before RFC 2047 decoding).
    static func parseAddresses(_ value: String) -> [Address] {
        var items: [String] = []
        var cur = ""
        var inQuote = false, escape = false
        var angle = 0, paren = 0
        for c in value {
            if escape { cur.append(c); escape = false; continue }
            switch c {
            case "\\" where inQuote: escape = true; cur.append(c); continue
            case "\"" where paren == 0: inQuote.toggle()
            case "<" where !inQuote && paren == 0: angle += 1
            case ">" where !inQuote && paren == 0: angle = max(0, angle - 1)
            case "(" where !inQuote: paren += 1
            case ")" where !inQuote: paren = max(0, paren - 1)
            case ",", ";":
                if !inQuote && angle == 0 && paren == 0 { items.append(cur); cur = ""; continue }
            default: break
            }
            cur.append(c)
        }
        items.append(cur)
        return items.compactMap(parseMailbox)
    }

    private static func parseMailbox(_ item: String) -> Address? {
        var s = item.trimmingCharacters(in: .whitespacesAndNewlines)
        // group syntax "Undisclosed recipients:" / "team: a@b"
        if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("<"), !s[..<colon].contains("\""), !s[..<colon].contains("@") {
            s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if s.isEmpty { return nil }
        var name = ""
        var addr = ""
        if let lt = s.lastIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">") {
            addr = String(s[s.index(after: lt)..<gt])
            name = String(s[..<lt])
        } else {
            addr = s
            // "a@b (Name)"
            if let lp = s.firstIndex(of: "("), let rp = s.lastIndex(of: ")"), lp < rp {
                name = String(s[s.index(after: lp)..<rp])
                addr = String(s[..<lp])
            }
        }
        addr = addr.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if addr.hasPrefix("mailto:") { addr.removeFirst(7) }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        name = decodeHeader(name).trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
        if addr.isEmpty && name.isEmpty { return nil }
        if !addr.contains("@") && name.isEmpty { name = decodeHeader(addr); addr = "" }
        return Address(name: name, address: addr)
    }
}
