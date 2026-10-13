import Foundation
import UniformTypeIdentifiers

/// Attachment listing and extraction. Part numbers follow IMAP BODYSTRUCTURE, which is also how Mail names the
/// folders under `Data/x/y/Attachments/<ROWID>/<part>/`.
enum MailAttachments {
    /// Every part with its IMAP number. A single-part message is "1"; children of a multipart at N are N.1, N.2…
    /// (top level: 1, 2…); an attached message at N numbers its own parts below N (a single-part body is N.1).
    static func numbered(_ root: MIMEPart) -> [(number: String, part: MIMEPart)] {
        var out: [(String, MIMEPart)] = []
        func visit(_ p: MIMEPart, _ n: String) {
            out.append((n, p))
            if p.isMessage, let inner = p.children.first {
                visitBody(inner, prefix: n)
            } else if !p.children.isEmpty {
                for (i, c) in p.children.enumerated() { visit(c, n + "." + String(i + 1)) }
            }
        }
        func visitBody(_ msg: MIMEPart, prefix: String?) {
            let at = { (i: Int) in prefix.map { "\($0).\(i)" } ?? String(i) }
            if msg.mimeType.hasPrefix("multipart/") && !msg.children.isEmpty {
                for (i, c) in msg.children.enumerated() { visit(c, at(i + 1)) }
            } else {
                visit(msg, at(1))
            }
        }
        visitBody(root, prefix: nil)
        return out
    }

    /// Leaf parts that are attachments rather than the readable body: everything except inline text/plain and
    /// text/html (those are the body, and an attached message's are inlined into bodyText too). Attached messages are
    /// listed as `.eml`, followed by their own attachments.
    static func list(_ root: MIMEPart, attachmentsDir: URL?) -> [Attachment] {
        numbered(root).compactMap { number, part in
            if part.mimeType.hasPrefix("multipart/") { return nil }
            if (part.mimeType == "text/plain" || part.mimeType == "text/html") && !part.isAttachment { return nil }
            return attachment(part, number: number, attachmentsDir: attachmentsDir)
        }
    }

    static func attachment(_ part: MIMEPart, number: String, attachmentsDir: URL?) -> Attachment {
        let disposition = MIME.parseParameterized(part.header("content-disposition") ?? "")
        let contentID = part.header("content-id").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        }.flatMap { $0.isEmpty ? nil : $0 }
        let onDisk = attachmentsDir.flatMap { diskFile(in: $0, part: number) }
        let bodyPresent = hasBody(part)
        var size: Int? = bodyPresent ? decodedSize(part) : nil
        if size == nil, let v = part.header("x-apple-content-length"), let n = Int(v.trimmingCharacters(in: .whitespaces)) { size = n }
        if size == nil, let f = onDisk { size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
        return Attachment(
            part: number, filename: filename(part), mimeType: part.mimeType, size: size, contentID: contentID,
            isInline: disposition.type == "inline" || (disposition.type.isEmpty && contentID != nil),
            isDownloaded: bodyPresent || onDisk != nil)
    }

    /// RFC 2231 / RFC 2047 filename from Content-Disposition or Content-Type, else a name from the subject (attached
    /// messages) or the MIME type.
    static func filename(_ part: MIMEPart) -> String {
        let disp = MIME.parseParameterized(part.header("content-disposition") ?? "").params
        if let raw = disp["filename"] ?? part.contentType.params["name"] {
            let name = MIME.decodeHeader(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            // Like Mail, give an extension-less name one from the MIME type so the file opens in the right app.
            if !name.isEmpty, (name as NSString).pathExtension.isEmpty, !part.isMessage,
               let ext = UTType(mimeType: part.mimeType)?.preferredFilenameExtension {
                return name + "." + ext
            }
            if !name.isEmpty { return name }
        }
        if part.isMessage {
            let subject = MIME.decodeHeader(part.children.first?.header("subject") ?? "").trimmingCharacters(in: .whitespaces)
            return (subject.isEmpty ? "Message" : subject) + ".eml"
        }
        let ext = UTType(mimeType: part.mimeType)?.preferredFilenameExtension
        return "Mail Attachment" + (ext.map { "." + $0 } ?? "")
    }

    /// True when the part's content is in the emlx (partial.emlx files keep headers but strip attachment bodies).
    static func hasBody(_ part: MIMEPart) -> Bool {
        !part.body.allSatisfy(isSpace)
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }

    /// Decoded size without decoding: base64 counts alphabet characters.
    static func decodedSize(_ part: MIMEPart) -> Int {
        switch (part.header("content-transfer-encoding") ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64" where !part.body.contains(where: { $0 >= 0x80 }):
            var n = 0
            for b in part.body {
                switch b {
                case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F, 0x2D, 0x5F: n += 1
                default: continue
                }
            }
            return n * 3 / 4
        case "quoted-printable": return part.decodedBody.count
        default: return part.body.count
        }
    }

    /// The file Mail saved for this part, if any.
    static func diskFile(in attachmentsDir: URL, part: String) -> URL? {
        let dir = attachmentsDir.appendingPathComponent(part, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().first.map { dir.appendingPathComponent($0) }
    }

    /// `…/Data/x/y/Messages/<id>[.partial].emlx` → `…/Data/x/y/Attachments/<id>`.
    static func attachmentsDir(forEmlx path: String, id: Int64) -> URL {
        URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Attachments").appendingPathComponent(String(id))
    }

    static func part(_ root: MIMEPart, number: String) -> MIMEPart? {
        numbered(root).first { $0.number == number }?.part
    }

    /// Safe single path component.
    static func sanitize(_ name: String) -> String {
        var s = String(name.unicodeScalars.map { u -> Character in
            (u.value < 0x20 || u == "/" || u == ":" || u == "\\") ? "_" : Character(u)
        }).trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.utf8.count > 200 {
            let ext = (s as NSString).pathExtension
            s = String(s.prefix(120)) + (ext.isEmpty ? "" : "." + ext)
        }
        return s.isEmpty ? "Attachment" : s
    }
}
