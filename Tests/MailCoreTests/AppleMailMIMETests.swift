import Foundation
import XCTest
@testable import MailCore

final class AppleMailMIMETests: XCTestCase {
    private func enc(_ s: String, _ cfEnc: CFStringEncodings) -> [UInt8] {
        let e = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue)))
        return Array(s.data(using: e)!)
    }
    private func b64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }
    private func message(_ s: String) -> MIMEPart { MIME.parse(Array(s.utf8)) }

    // MARK: Headers

    func testEncodedWordsBAndQ() {
        XCTAssertEqual(MIME.decodeHeader("=?UTF-8?B?5Lit5paH?="), "中文")
        XCTAssertEqual(MIME.decodeHeader("=?iso-8859-1?Q?Caf=E9_au_lait?="), "Café au lait")
        XCTAssertEqual(MIME.decodeHeader("Re: =?utf-8?q?hello?= world"), "Re: hello world")
    }

    func testAdjacentEncodedWordsJoinAndSplitMultibyte() {
        // "中文" = E4 B8 AD E6 96 87 split mid-character across two words.
        let w1 = b64([0xE4, 0xB8]), w2 = b64([0xAD, 0xE6, 0x96, 0x87])
        XCTAssertEqual(MIME.decodeHeader("=?UTF-8?B?\(w1)?=\n =?UTF-8?B?\(w2)?="), "中文")
        XCTAssertEqual(MIME.decodeHeader("=?UTF-8?Q?a?= =?UTF-8?Q?b?="), "ab")
        // Folded inside a B word, with a stray space before "?=".
        XCTAssertEqual(MIME.decodeHeader("=?UTF-8?B?5Lit 5paH ?= x"), "中文 x")
        XCTAssertEqual(MIME.decodeHeader("=?UTF-8?Q?a b?="), "=?UTF-8?Q?a b?=")
    }

    func testCJKCharsets() {
        XCTAssertEqual(MIME.decodeHeader("=?big5?B?\(b64(enc("臺北市立圖書館", .big5)))?="), "臺北市立圖書館")
        // 镕 is GBK-only (not in GB2312); mail labelled gb2312 still decodes.
        XCTAssertEqual(MIME.decodeHeader("=?gb2312?B?\(b64(enc("朱镕基", .GB_18030_2000)))?="), "朱镕基")
        XCTAssertEqual(MIME.decodeHeader("=?ISO-2022-JP?B?GyRCJEskWyRzGyhC?="), "にほん")
        XCTAssertEqual(MIME.decodeHeader("=?windows-1252?Q?=80_and_=93q=94?="), "€ and “q”")
    }

    func testRawEightBitHeaderUsesBodyCharset() {
        var bytes = Array("Subject: ".utf8) + enc("資料庫期末考", .big5) + Array("\nContent-Type: text/plain; charset=big5\n\nx".utf8)
        XCTAssertEqual(MIME.decodeHeader(MIME.parse(bytes).header("subject")!), "資料庫期末考")
        bytes = Array("Subject: 中文標題\n\nx".utf8)
        XCTAssertEqual(MIME.parse(bytes).header("subject"), "中文標題")
    }

    func testFoldingAndAddresses() {
        let m = message("From: \"Doe, John\" <john@x.com>\nTo: a@b.com, =?UTF-8?B?5byg5LiJ?= <zhang@c.com>,\n  \"Q \\\"x\\\"\" <q@d.com>\nCc: e@f.com (Eve)\nSubject: long\n  subject\n\nbody")
        XCTAssertEqual(m.header("subject"), "long  subject")
        XCTAssertEqual(MIME.parseAddresses(m.header("from")!), [.init(name: "Doe, John", address: "john@x.com")])
        XCTAssertEqual(MIME.parseAddresses(m.header("to")!), [
            .init(name: "", address: "a@b.com"), .init(name: "张三", address: "zhang@c.com"), .init(name: "Q \"x\"", address: "q@d.com"),
        ])
        XCTAssertEqual(MIME.parseAddresses(m.header("cc")!), [.init(name: "Eve", address: "e@f.com")])
        XCTAssertEqual(MIME.parseAddresses("\"=?UTF-8?B?5byg5LiJ?=\" <z@c.com>"), [.init(name: "张三", address: "z@c.com")])
        XCTAssertEqual(MIME.parseAddresses("undisclosed-recipients:;"), [])
    }

    func testParameters() {
        let p = MIME.parseParameterized("TEXT/PLAIN;\n\tcharset=\"Big5\"; name*=utf-8''%E4%B8%AD.txt; x*0=\"ab\"; x*1=cd")
        XCTAssertEqual(p.type, "text/plain")
        XCTAssertEqual(p.params["charset"], "Big5")
        XCTAssertEqual(p.params["name"], "中.txt")
        XCTAssertEqual(p.params["x"], "abcd")
    }

    // MARK: Bodies

    func testTransferEncodings() {
        XCTAssertEqual(MIME.decodeQuotedPrintable(Array("caf=C3=A9 =\nok=3D".utf8), header: false), Array("café ok=".utf8))
        XCTAssertEqual(MIME.decodeBase64(Array("5Lit\n5paH".utf8)), Array("中文".utf8))
        XCTAssertEqual(MIME.decodeBase64(Array("YQ==".utf8)), Array("a".utf8))
        XCTAssertEqual(MIME.decodeBase64(Array("YWI".utf8)), Array("ab".utf8))
    }

    func testNestedMultipartPrefersPlainAndSkipsAttachments() {
        let raw = """
        Content-Type: multipart/mixed; boundary="outer"

        preamble
        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        \(b64(Array("你好，世界".utf8)))
        --inner
        Content-Type: text/html; charset=utf-8

        <p>HTML version</p>
        --inner--
        --outer
        Content-Type: text/plain; name="notes.txt"
        Content-Disposition: attachment; filename="notes.txt"

        attachment text
        --outer--
        """
        let body = MailText.body(of: message(raw.replacingOccurrences(of: "\n", with: "\r\n")))
        XCTAssertEqual(body.text, "你好，世界")
        XCTAssertEqual(body.html?.trimmingCharacters(in: .whitespacesAndNewlines), "<p>HTML version</p>")
    }

    func testHTMLOnlyAndBoundaryRightAfterHeaders() {
        let raw = """
        Content-Type: multipart/alternative; boundary=b
        --b
        Content-Type: text/html; charset=big5
        Content-Transfer-Encoding: quoted-printable

        <html><head><title>T</title><style>p{}</style></head><body>
        <!-- hidden --><p>=A4=A4=A4=E5</p><div>a&amp;b&nbsp;&#x4E2D;&#25991;</div>
        <ul><li>one</li><li>two</li></ul><script>x()</script></body></html>
        --b--
        """
        let body = MailText.body(of: message(raw))
        XCTAssertEqual(body.text, "中文\n\na&b 中文\n\none\n\ntwo")
    }

    func testCharsetFallbacks() {
        // Declared big5 with one stray byte: stay in big5, don't flip the whole part.
        let bytes = enc("請注意", .big5) + [0x8F] + enc("本郵件", .big5)
        let s = Charsets.decode(bytes, charset: "big5")
        XCTAssertTrue(s.hasPrefix("請注意") && s.hasSuffix("本郵件"), s)
        // Mislabelled: utf-8 bytes declared as big5.
        XCTAssertEqual(Charsets.decode(Array("中文".utf8), charset: "big5"), "中文")
        // Undeclared big5.
        XCTAssertEqual(Charsets.decode(enc("繁體", .big5), charset: nil), "繁體")
        // Declared utf-8 with a broken byte keeps the rest.
        XCTAssertEqual(Charsets.decode(Array("中文".utf8) + [0xFF] + Array("字".utf8), charset: "utf-8"), "中文\u{FFFD}字")
    }

    func testBase64LabelOnRawText() {
        let raw = "Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n親愛的會員您好"
        XCTAssertEqual(MailText.body(of: message(raw)).text, "親愛的會員您好")
    }

    // MARK: Quotes

    func testQuoteStripping() {
        XCTAssertEqual(MailText.stripQuotes("Thanks!\n\nOn Mon, Jan 1, 2024 at 10:00 AM Bob <b@x.com> wrote:\n> old"), "Thanks!\n")
        XCTAssertEqual(MailText.stripQuotes("Thanks!\nOn Mon, Jan 1, 2024 at 10:00 AM Bob <b@x.com>\nwrote:\n> old"), "Thanks!")
        XCTAssertEqual(MailText.stripQuotes("好\n\n王小明 <w@x.com> 於 2024年1月1日 週一 上午10:00寫道：\n舊的"), "好\n")
        XCTAssertEqual(MailText.stripQuotes("好\n在 2024年1月1日 周一 10:00，张三 <z@x.com> 写道：\n旧"), "好")
        XCTAssertEqual(MailText.stripQuotes("ok\n-----Original Message-----\nFrom: x"), "ok")
        XCTAssertEqual(MailText.stripQuotes("ok\n--------------- 原始郵件 ---------------\n寄件者: x"), "ok")
        XCTAssertEqual(MailText.stripQuotes("new\n> quoted\nmore"), "new\nmore")
        XCTAssertEqual(MailText.stripQuotes("see below\nFrom: A <a@x.com>\nSent: Tuesday\nTo: B\nSubject: RE: x\n\nold"), "see below")
        // A notification with From/Date but no To/Subject is content, not a quote header.
        XCTAssertEqual(MailText.stripQuotes("Hi\nFrom: Simon\nDate: 2023/11/20\nView message"), "Hi\nFrom: Simon\nDate: 2023/11/20\nView message")
        // Forward with a note cuts; a bare forward keeps the forwarded content.
        XCTAssertEqual(MailText.stripQuotes("FYI\n---------- Forwarded message ---------\nFrom: x\nbody"), "FYI")
        XCTAssertEqual(MailText.stripQuotes("---------- Forwarded message ---------\nFrom: x\nbody"),
                       "---------- Forwarded message ---------\nFrom: x\nbody")
        // Bottom-posted reply: header first, nothing above it → keep everything.
        XCTAssertEqual(MailText.stripQuotes("Bob <b@x.com> 於 2015/1/1 寫道：\nquoted\n\nmy answer"),
                       "Bob <b@x.com> 於 2015/1/1 寫道：\nquoted\n\nmy answer")
    }

    func testNormalize() {
        XCTAssertEqual(MailText.normalize("  a   b \n\n\n\n c\u{200C}\u{034F}\u{00AD}\nd\t\te  "), "a b\n\nc\nd e")
    }

    func testEmlx() {
        let msg = "Subject: x\n\nhello"
        let data = Data("\(msg.utf8.count)\n\(msg)<?xml version=\"1.0\"?><plist/>".utf8)
        XCTAssertEqual(String(decoding: Emlx.messageBytes(data), as: UTF8.self), msg)
    }
}
