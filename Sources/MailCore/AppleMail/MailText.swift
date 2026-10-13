import Foundation

/// Turns a parsed MIME tree into readable text.
enum MailText {
    /// Picks the body: first non-empty text/plain leaf, else the first text/html leaf converted to text.
    /// Attached messages (message/rfc822, i.e. forwarded as attachment) follow, each as its subject and body.
    /// Returns (bodyText, html). Other attachments are skipped.
    static func body(of root: MIMEPart) -> (text: String, html: String?) {
        var plain: String? = nil
        var html: String? = nil
        var attached: [String] = []
        for leaf in root.leaves() {
            if leaf.isMessage, let inner = leaf.children.first {
                let subject = normalize(MIME.decodeHeader(inner.header("subject") ?? ""))
                let text = [subject, body(of: inner).text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !text.isEmpty { attached.append(text) }
                continue
            }
            if leaf.isAttachment { continue }
            switch leaf.mimeType {
            case "text/plain" where plain == nil:
                let t = leaf.text
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { plain = t }
            case "text/html" where html == nil:
                html = leaf.text
            default: break
            }
        }
        let raw = plain ?? html.map(htmlToText) ?? ""
        let main = normalize(stripQuotes(raw))
        return (([main] + attached).filter { !$0.isEmpty }.joined(separator: "\n\n"), html)
    }

    // MARK: HTML

    private static let dropBlocks = try! NSRegularExpression(
        pattern: "<(script|style|head|title)\\b[^>]*>.*?</\\1\\s*>|<!--.*?-->", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let breakTags = try! NSRegularExpression(
        pattern: "<(br|/?p|/?div|/?tr|/?li|/?h[1-6]|/?table|/?blockquote|/?ul|/?ol|hr)\\b[^>]*>", options: [.caseInsensitive])
    private static let anyTag = try! NSRegularExpression(pattern: "<[^>]*>", options: [])

    static func htmlToText(_ html: String) -> String {
        var s = html
        s = dropBlocks.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        s = breakTags.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n")
        s = anyTag.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        return decodeEntities(s)
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ",
        "thinsp": " ", "zwnj": "", "zwj": "", "shy": "", "copy": "©", "reg": "®", "trade": "™", "hellip": "…",
        "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "sbquo": "‚",
        "bdquo": "„", "laquo": "«", "raquo": "»", "bull": "•", "middot": "·", "euro": "€", "pound": "£",
        "yen": "¥", "cent": "¢", "deg": "°", "times": "×", "divide": "÷", "plusmn": "±", "sect": "§",
        "para": "¶", "dagger": "†", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "frac12": "½",
        "frac14": "¼", "frac34": "¾", "iexcl": "¡", "iquest": "¿", "eacute": "é", "egrave": "è", "aacute": "á",
        "agrave": "à", "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß", "ccedil": "ç", "ntilde": "ñ",
        "oacute": "ó", "iacute": "í", "uacute": "ú", "check": "✓", "star": "☆", "hearts": "♥", "zwsp": "",
    ]

    /// Works on scalars: a combining mark after ";" (preheader padding like "&nbsp;\u{034F}") would otherwise fuse
    /// with it into one Character.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            guard u[i] == "&", let semi = (i + 1..<min(i + 12, u.count)).first(where: { u[$0] == ";" }) else {
                out.append(u[i]); i += 1; continue
            }
            var name = String.UnicodeScalarView()
            name.append(contentsOf: u[(i + 1)..<semi])
            let key = String(name)
            var rep: String? = nil
            if key.hasPrefix("#") {
                let num = key.dropFirst()
                let v = num.first == "x" || num.first == "X" ? UInt32(num.dropFirst(), radix: 16) : UInt32(num, radix: 10)
                if let v, let scalar = Unicode.Scalar(v) { rep = v == 0xA0 ? " " : String(scalar) }
            } else {
                rep = entities[key] ?? entities[key.lowercased()]
            }
            if let rep { out.append(contentsOf: rep.unicodeScalars); i = semi + 1 } else { out.append(u[i]); i += 1 }
        }
        return String(out)
    }

    // MARK: Quotes

    private static let cutMarker = try! NSRegularExpression(
        pattern: "^-{2,} ?(original message|原始郵件|原始邮件) ?-{2,}$", options: [.caseInsensitive])
    private static let forwardMarker = try! NSRegularExpression(
        pattern: "^(-{2,} ?(forwarded message|轉寄的郵件|转发的邮件|已轉寄的郵件|轉寄郵件) ?-{2,}|begin forwarded message:|開始轉寄的郵件：|转发的邮件：)$",
        options: [.caseInsensitive])

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Drops ">"-quoted lines and everything from a reply header ("On … wrote:", "…寫道：", "Original Message",
    /// an Outlook "From:/Sent:/To:" block). Forwarded content is kept: the header block right after a forward marker,
    /// and Outlook blocks whose subject is "FW:/Fwd:", don't cut.
    static func stripQuotes(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var inForwardHeader = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") || t.hasPrefix("＞") { i += 1; continue }
            if t.count < 60, matches(forwardMarker, t) { inForwardHeader = true }
            else if t.isEmpty { inForwardHeader = false }
            else if !inForwardHeader {
                let outlook = isOutlookHeader(lines, at: i) && !isForwardBlock(lines, at: i)
                    && kept.contains { !$0.allSatisfy(\.isWhitespace) }
                if outlook || (t.hasPrefix("-") && matches(cutMarker, t))
                    || isReplyHeader(t, next: i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : "") {
                    break
                }
            }
            kept.append(line)
            i += 1
        }
        let out = kept.joined(separator: "\n")
        // Bottom-posted replies start with the reply header; keep everything rather than return nothing.
        return out.allSatisfy(\.isWhitespace) ? text : out
    }

    private static let forwardSubject = try! NSRegularExpression(
        pattern: "^(subject|主旨|主题)[:：]\\s*(fw|fwd|轉寄|转发)\\s*[:：]", options: [.caseInsensitive])

    /// An Outlook header block whose Subject line starts with FW:/Fwd: introduces a forward, not a quoted reply.
    private static func isForwardBlock(_ lines: [Substring], at i: Int) -> Bool {
        (i + 1..<min(i + 6, lines.count)).contains { matches(forwardSubject, lines[$0].trimmingCharacters(in: .whitespaces)) }
    }

    private static let headerFrom = ["From:", "寄件者:", "寄件者：", "发件人:", "发件人：", "寄件人:", "寄件人："]
    private static let headerDate = ["Sent:", "Date:", "傳送時間:", "傳送時間：", "寄件日期:", "寄件日期：", "发送时间:", "发送时间：",
                                     "日期:", "日期："]

    private static let headerTo = ["To:", "Subject:", "收件者:", "收件者：", "收件人:", "收件人：", "主旨:", "主旨：", "主题:", "主题："]

    /// Outlook-style reply block: "From: …" followed within a few lines by "Sent:/Date: …" and "To:/Subject: …".
    private static func isOutlookHeader(_ lines: [Substring], at i: Int) -> Bool {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        guard headerFrom.contains(where: { t.hasPrefix($0) }) else { return false }
        var date = false, to = false
        for j in (i + 1)..<min(i + 6, lines.count) {
            let n = lines[j].trimmingCharacters(in: .whitespaces)
            if headerDate.contains(where: { n.hasPrefix($0) }) { date = true }
            if headerTo.contains(where: { n.hasPrefix($0) }) { to = true }
        }
        return date && to
    }

    private static func isReplyHeader(_ t: String, next: String) -> Bool {
        guard t.count < 400 else { return false }
        if t.hasPrefix("On ") && (t.hasSuffix("wrote:") || (next.hasSuffix("wrote:") && next.count < 200)) { return true }
        for suffix in ["寫道：", "寫道:", "寫道﹕", "写道：", "写道:", "写道﹕"] where t.hasSuffix(suffix) { return true }
        return false
    }

    // MARK: Whitespace

    /// Collapses runs of spaces within lines and blank-line runs to one paragraph break.
    static func normalize(_ text: String) -> String {
        // Invisible preheader padding and stray control characters carry nothing searchable.
        var cleaned = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            switch u.value {
            case 0x0A, 0x09: cleaned.append(u)
            case 0x00...0x1F, 0x7F, 0xAD, 0x034F, 0x200B, 0x200C, 0x2060, 0xFEFF: continue
            default: cleaned.append(u)
            }
        }
        let text = String(cleaned)
        var paragraphs: [String] = []
        var cur: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if line.isEmpty {
                if !cur.isEmpty { paragraphs.append(cur.joined(separator: "\n")); cur = [] }
            } else {
                cur.append(line)
            }
        }
        if !cur.isEmpty { paragraphs.append(cur.joined(separator: "\n")) }
        return paragraphs.joined(separator: "\n\n")
    }
}
