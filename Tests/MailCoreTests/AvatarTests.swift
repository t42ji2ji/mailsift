import XCTest
@testable import MailCore

final class AvatarTests: XCTestCase {
    func testBIMILogo() {
        XCTAssertEqual(AvatarStore.bimiLogo("v=BIMI1; l=https://vmc.digicert.com/x.svg; a=https://vmc.digicert.com/x.pem")?.absoluteString,
                       "https://vmc.digicert.com/x.svg")
        XCTAssertEqual(AvatarStore.bimiLogo("v=BIMI1;l=https://img.clerk.com/static/clerk.svg")?.absoluteString,
                       "https://img.clerk.com/static/clerk.svg")
        XCTAssertNil(AvatarStore.bimiLogo("v=BIMI1; l=; a=; lps=googlewallet-noreply-bimi"))
        XCTAssertNil(AvatarStore.bimiLogo("v=spf1 include:_spf.google.com ~all"))
        XCTAssertNil(AvatarStore.bimiLogo("v=BIMI1; l=http://example.com/logo.svg"))
    }

    func testSiteDomain() {
        XCTAssertEqual(AvatarStore.siteDomain("mail.notion.so"), "notion.so")
        XCTAssertEqual(AvatarStore.siteDomain("notion.so"), "notion.so")
        XCTAssertEqual(AvatarStore.siteDomain("mailhunter.megabank.com.tw"), "megabank.com.tw")
        XCTAssertEqual(AvatarStore.siteDomain("edm.linebank.com.tw"), "linebank.com.tw")
        XCTAssertEqual(AvatarStore.siteDomain("sg.newsletter.agoda-emails.com"), "agoda-emails.com")
    }

    func testGravatarHash() {
        XCTAssertEqual(AvatarStore.sha256("myemailaddress@example.com"), "84059b07d4be67b806386c0aad8070a23f18836bbaae342275dc0a83414c32ee")
    }

    func testCachedMissNeedsNoNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AvatarStore(dir: dir)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("g-" + AvatarStore.sha256("a@b.example")))
        let hit = await store.image(for: " A@B.example ", online: false)
        XCTAssertEqual(hit, png)
        let none = await store.image(for: "x@gmail.com", online: false)
        XCTAssertNil(none)
    }
}
