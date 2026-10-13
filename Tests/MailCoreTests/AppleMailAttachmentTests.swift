import Foundation
import XCTest
@testable import MailCore

final class AppleMailAttachmentTests: XCTestCase {
    private func message(_ s: String) -> MIMEPart { MIME.parse(Array(s.utf8)) }

    func testPartNumbering() {
        let inner = "Subject: Inner\nContent-Type: multipart/mixed; boundary=i\n\n--i\nContent-Type: text/plain\n\ninner body\n--i\nContent-Type: image/png; name=a.png\nContent-Transfer-Encoding: base64\n\niVBORw0K\n--i--\n"
        let raw = """
        Content-Type: multipart/mixed; boundary=o

        --o
        Content-Type: multipart/alternative; boundary=a

        --a
        Content-Type: text/plain

        plain
        --a
        Content-Type: multipart/related; boundary=r

        --r
        Content-Type: text/html

        <p>html</p>
        --r
        Content-Type: image/gif
        Content-ID: <logo@x>

        GIF89a
        --r--
        --a--
        --o
        Content-Type: application/pdf
        Content-Disposition: attachment; filename="r.pdf"

        %PDF
        --o
        Content-Type: message/rfc822

        \(inner)
        --o
        Content-Type: text/calendar; method=REQUEST

        BEGIN:VCALENDAR
        --o--
        """
        let root = message(raw)
        let numbers = MailAttachments.numbered(root).map(\.number)
        XCTAssertEqual(numbers, ["1", "1.1", "1.2", "1.2.1", "1.2.2", "2", "3", "3.1", "3.2", "4"])
        let atts = MailAttachments.list(root, attachmentsDir: nil)
        XCTAssertEqual(atts.map(\.part), ["1.2.2", "2", "3", "3.2", "4"])
        XCTAssertEqual(atts.map(\.filename), ["Mail Attachment.gif", "r.pdf", "Inner.eml", "a.png", "Mail Attachment.ics"])
        XCTAssertEqual(atts[0].contentID, "logo@x")
        XCTAssertTrue(atts[0].isInline)
        XCTAssertFalse(atts[1].isInline)
        XCTAssertEqual(atts[3].size, 6)       // base64 "iVBORw0K" → 6 bytes
        XCTAssertTrue(atts.allSatisfy(\.isDownloaded))
        // Single-part messages: the body is part 1; an attached single-part message's body is N.1.
        XCTAssertEqual(MailAttachments.numbered(message("Content-Type: application/pdf\n\n%PDF")).map(\.number), ["1"])
        XCTAssertEqual(MailAttachments.list(message("Content-Type: application/pdf\n\n%PDF"), attachmentsDir: nil).map(\.part), ["1"])
        let fwd = message("Content-Type: multipart/mixed; boundary=o\n\n--o\nContent-Type: text/plain\n\nhi\n--o\nContent-Type: message/rfc822\n\nSubject: s\n\nbody\n--o--\n")
        XCTAssertEqual(MailAttachments.numbered(fwd).map(\.number), ["1", "2", "2.1"])
        // bodyText is unaffected by attachment listing.
        XCTAssertEqual(MailText.body(of: fwd).text, "hi\n\ns\n\nbody")
    }

    func testFilenames() {
        let cases: [(String, String)] = [
            ("Content-Type: application/pdf\nContent-Disposition: attachment; filename*=UTF-8''%E5%A0%B1%E5%91%8A.pdf", "報告.pdf"),
            ("Content-Type: application/pdf\nContent-Disposition: attachment;\n filename*0*=UTF-8''%E5%A0%B1; filename*1*=%E5%91%8A; filename*2=.pdf", "報告.pdf"),
            ("Content-Type: text/plain; charset=Big5;\n name=\"=?UTF-8?Q?V3619020=E8=91=89=E7=B0=A1=E9=8A=93.txt?=\"\nContent-Disposition: ATTACHMENT", "V3619020葉簡銓.txt"),
            ("Content-Type: application/octet-stream; name=\"=?big5?B?pOWl8y5kb2M=?=\"", "文件.doc"),
            ("Content-Type: image/jpeg\nContent-ID: <x>", "Mail Attachment.jpeg"),
        ]
        for (headers, expected) in cases {
            let root = message(headers + "\n\nx")
            XCTAssertEqual(MailAttachments.filename(root), expected, headers)
        }
    }

    func testPartialPartSizeAndDownload() {
        let raw = "Content-Type: multipart/mixed; boundary=o\n\n--o\nContent-Type: text/plain\n\nhi\n--o\nContent-Type: application/pdf; name=a.pdf\nContent-Disposition: attachment\nX-Apple-Content-Length: 770\n\n\n--o--\n"
        let a = MailAttachments.list(message(raw), attachmentsDir: nil)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].size, 770)
        XCTAssertFalse(a[0].isDownloaded)
    }

    func testSanitize() {
        XCTAssertEqual(MailAttachments.sanitize("a/b:c.pdf"), "a_b_c.pdf")
        XCTAssertEqual(MailAttachments.sanitize("..hidden"), "hidden")
        XCTAssertEqual(MailAttachments.sanitize(""), "Attachment")
    }

    func testAttachmentFileExtractsAndCaches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mailsift-att-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let msgDir = dir.appendingPathComponent("V10/ACC/INBOX.mbox/U/Data/Messages")
        try FileManager.default.createDirectory(at: msgDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("V10/MailData"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("V10/MailData/Envelope Index").path, contents: Data())
        let msg = "Content-Type: multipart/mixed; boundary=o\n\n--o\nContent-Type: text/plain\n\nhi\n--o\nContent-Type: application/octet-stream; name=\"x/y.bin\"\nContent-Transfer-Encoding: base64\n\nAAECAw==\n--o\nContent-Type: application/pdf; name=p.pdf\nX-Apple-Content-Length: 9\n\n\n--o--\n"
        try Data("\(msg.utf8.count)\n\(msg)".utf8).write(to: msgDir.appendingPathComponent("7.partial.emlx"))
        let src = AppleMailSource(libraryMail: dir, cachesRoot: dir.appendingPathComponent("cache"))
        let meta = MessageMeta(id: 7, mailbox: MailboxRef(id: 1, account: "a", name: "INBOX", role: .inbox), date: Date(),
                               subject: "", senderAddress: "", senderName: "", isRead: false, isFlagged: false)
        let parsed = try src.parse(meta)
        XCTAssertEqual(parsed.attachments.map(\.part), ["2", "3"])
        XCTAssertEqual(parsed.attachments.map(\.isDownloaded), [true, false])

        let url = try src.attachmentFile(meta, parsed.attachments[0])
        XCTAssertEqual(url.lastPathComponent, "x_y.bin")
        XCTAssertTrue(url.path.hasSuffix("cache/7/2/x_y.bin"))
        XCTAssertEqual(try Data(contentsOf: url), Data([0, 1, 2, 3]))
        XCTAssertThrowsError(try src.attachmentFile(meta, parsed.attachments[1]))

        // Mail's saved copy wins.
        let saved = dir.appendingPathComponent("V10/ACC/INBOX.mbox/U/Data/Attachments/7/3")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try Data("%PDF-real".utf8).write(to: saved.appendingPathComponent("p.pdf"))
        let reparsed = try src.parse(meta)
        XCTAssertEqual(reparsed.attachments[1].isDownloaded, true)
        XCTAssertEqual(try src.attachmentFile(meta, reparsed.attachments[1]).path, saved.appendingPathComponent("p.pdf").path)
    }

    /// Compares part numbers with the folders Mail created under Attachments/<id>/ (this machine only).
    func testPartNumbersMatchMailFoldersOnRealStore() throws {
        let src = AppleMailSource()
        do { try src.checkAccess() } catch { throw XCTSkip("Apple Mail store not readable") }
        let files = try src.messageFiles()
        var withFolders: [(Int64, String, [String])] = []
        for (id, path) in files {
            let dir = MailAttachments.attachmentsDir(forEmlx: path, id: id)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            let parts = names.filter { !$0.hasPrefix(".") }
            if !parts.isEmpty { withFolders.append((id, path, parts)) }
        }
        withFolders.sort { $0.0 < $1.0 }
        let limit = Int(ProcessInfo.processInfo.environment["MAILSIFT_ATTACH_LIMIT"] ?? "") ?? 400
        let step = max(1, withFolders.count / limit)
        var folders = 0, matched = 0, nameMatched = 0, downloaded = 0, misses: [String] = [], nameMisses: [String] = []
        for (id, path, parts) in stride(from: 0, to: withFolders.count, by: step).map({ withFolders[$0] }) {
            let p = try XCTUnwrap(try AppleMailSource.parseFile(path: path, id: id))
            for part in parts {
                folders += 1
                guard let a = p.attachments.first(where: { $0.part == part }) else {
                    if misses.count < 15 { misses.append("\(id)/\(part)") }
                    continue
                }
                matched += 1
                if a.isDownloaded { downloaded += 1 }
                let dir = MailAttachments.attachmentsDir(forEmlx: path, id: id).appendingPathComponent(part)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                // Mail localizes the default name ("郵件附件.png"); ours is "Mail Attachment.png".
                let localizedDefault = a.filename.hasPrefix("Mail Attachment") && names.contains { $0.hasSuffix((a.filename as NSString).pathExtension) }
                if localizedDefault || names.contains(a.filename) || names.contains(MailAttachments.sanitize(a.filename)) { nameMatched += 1 }
                else if nameMisses.count < 12 { nameMisses.append("\(a.filename) | \(names.first ?? "-")") }
            }
        }
        let pct = { (k: Int) in String(format: "%.1f%%", 100 * Double(k) / Double(max(folders, 1))) }
        print("attachments: \(withFolders.count) messages with Attachments/ folders; sampled folders=\(folders) " +
              "partMatch=\(pct(matched)) filenameMatch=\(pct(nameMatched)) isDownloaded=\(pct(downloaded)) misses=\(misses)")
        if ProcessInfo.processInfo.environment["MAILSIFT_ATTACH_NAMES"] != nil { print(nameMisses.joined(separator: "\n")) }
        XCTAssertGreaterThanOrEqual(folders, 200)
        XCTAssertGreaterThanOrEqual(Double(matched) / Double(folders), 0.98)
    }
}
