import Foundation
import XCTest
@testable import MailCore

final class AppleMailStoreTests: XCTestCase {
    func testMailboxURLAndRoles() {
        let mb = AppleMailbox(id: 1, url: "imap://8E1C8CDF-2D49-45D2-B40A-CC68BE1172B0/%5BGmail%5D/%E5%85%A8%E9%83%A8%E9%83%B5%E4%BB%B6")!
        XCTAssertEqual(mb.accountUUID, "8E1C8CDF-2D49-45D2-B40A-CC68BE1172B0")
        XCTAssertEqual(mb.path, "[Gmail]/全部郵件")
        XCTAssertEqual(mb.role, .allMail)
        let cases: [(String, MailboxRole)] = [
            ("[Gmail]/All Mail", .allMail), ("[Gmail]/所有邮件", .allMail), ("INBOX", .inbox),
            ("[Gmail]/Trash", .trash), ("[Gmail]/垃圾桶", .trash), ("[Gmail]/已删除邮件", .trash), ("Deleted Messages", .trash),
            ("[Gmail]/Spam", .spam), ("[Gmail]/垃圾郵件", .spam), ("[Gmail]/垃圾邮件", .spam), ("Junk", .spam),
            ("[Gmail]/Drafts", .drafts), ("[Gmail]/草稿", .drafts), ("Drafts", .drafts),
            ("[Gmail]/Sent Mail", .sent), ("[Gmail]/寄件備份", .sent), ("[Gmail]/已发邮件", .sent), ("Sent Messages", .sent),
            ("[Gmail]/Starred", .flagged), ("[Gmail]/已加星號", .flagged), ("[Gmail]/Important", .important),
            ("[Gmail]/重要郵件", .important), ("Archive", .archive), ("[Google Mail]/Bin", .trash),
            ("Work", .other), ("Work/Archive", .other), ("Tech週報", .other),
        ]
        for (path, role) in cases { XCTAssertEqual(MailboxRoles.role(forPath: path), role, path) }
        XCTAssertTrue(MailboxRoles.isExcluded(AppleMailbox(id: 2, url: "local://X/Outbox")!))
    }

    // MARK: Scripts

    func testMessageFilePaths() {
        // Paths seen in a real store.
        let cases: [(Int64, String)] = [(48166, "8/4/"), (119855, "9/1/1/"), (125252, "5/2/1/"), (7, "")]
        for (id, levels) in cases {
            XCTAssertEqual(AppleMailSource.messageFileCandidates(id, storeDir: "S"),
                           ["S/Data/\(levels)Messages/\(id).emlx", "S/Data/\(levels)Messages/\(id).partial.emlx"])
        }
    }

    func testScriptText() {
        let src = MailScript.MailboxSpec(accountUUID: "ABC", path: "[Gmail]/全部郵件")
        let s = MailScript.script(.markRead, ids: [1, 22], source: src)
        XCTAssertTrue(s.contains("set mb to mailbox \"[Gmail]/全部郵件\" of account id \"ABC\""))
        XCTAssertTrue(s.contains("repeat with i in {1, 22}"))
        XCTAssertTrue(s.contains("set read status of («class mssg» id (contents of i) of mb) to true"))
        XCTAssertTrue(MailScript.script(.trash, ids: [1], source: src).contains("delete («class mssg» id (contents of i) of mb)"))
        let archive = MailScript.script(.archive, ids: [1], source: MailScript.MailboxSpec(accountUUID: "ABC", path: "INBOX"), target: src)
        XCTAssertTrue(archive.contains("move («class mssg» id (contents of i) of mb) to mailbox \"[Gmail]/全部郵件\" of account id \"ABC\""))
        XCTAssertEqual(MailScript.MailboxSpec(accountUUID: nil, path: "a\"b").reference, "mailbox \"a\\\"b\"")
        XCTAssertEqual(MailScript.failures(fromOutput: "5\t-1728 Can’t get message.\n7\t-10000 x\n"), [5: "-1728 Can’t get message.", 7: "-10000 x"])
    }

    /// Runs osascript for real, without addressing Mail.
    func testScriptRunner() async throws {
        let out = try await MailScriptRunner.run("return \"1\" & tab & \"ok\" & linefeed & \"2\" & tab & \"x\"")
        XCTAssertEqual(MailScript.failures(fromOutput: out), [1: "ok", 2: "x"])
        do { _ = try await MailScriptRunner.run("error \"denied\" number -1743"); XCTFail("expected throw") }
        catch MailSourceError.automationDenied {}
        do { _ = try await MailScriptRunner.run("error \"boom\" number -2700"); XCTFail("expected throw") }
        catch MailSourceError.other(let msg) { XCTAssertTrue(msg.contains("boom"), msg) }
    }

    /// Compiles (never runs) every generated script against Mail's dictionary.
    func testScriptsCompile() throws {
        guard FileManager.default.fileExists(atPath: "/System/Applications/Mail.app") else { throw XCTSkip("no Mail.app") }
        let src = MailScript.MailboxSpec(accountUUID: "00000000-0000-0000-0000-000000000000", path: "[Gmail]/All Mail")
        let dst = MailScript.MailboxSpec(accountUUID: "00000000-0000-0000-0000-000000000000", path: "INBOX")
        for action in MailAction.allCases {
            let script = MailScript.script(action, ids: [1, 2], source: src, target: action == .archive ? dst : nil)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("mailsift-\(action).scpt")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            p.arguments = ["-o", out.path, "-e", script]
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(p.terminationStatus, 0, "\(action): \(msg)")
            try? FileManager.default.removeItem(at: out)
        }
    }

    // MARK: Real store (this machine only)

    private func realSource() throws -> AppleMailSource {
        let src = AppleMailSource()
        do { try src.checkAccess() } catch { throw XCTSkip("Apple Mail store not readable: \(error)") }
        return src
    }

    func testLocateFindsTrashedMessageOnRealStore() throws {
        let src = try realSource()
        guard let m = try src.listMailbox(.trash).first else { throw XCTSkip("Trash is empty") }
        let t0 = Date()
        let id = try src.locate(m, in: .trash)
        print("locate: \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
        XCTAssertEqual(id, m.id)
    }

    func testListMessagesOnRealStore() throws {
        let src = try realSource()
        let t0 = Date()
        let all = try src.listMessages()
        let elapsed = Date().timeIntervalSince(t0)
        var byAccount: [String: Int] = [:]
        for m in all { byAccount[m.mailbox.account, default: 0] += 1 }
        print("listMessages: \(all.count) in \(String(format: "%.2f", elapsed)) s; by account: \(byAccount.sorted { $0.key < $1.key })")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "duplicate ids")
        XCTAssertFalse(all.contains { [.trash, .spam, .drafts].contains($0.mailbox.role) })
        XCTAssertTrue(all.allSatisfy { $0.mailbox.account.contains("@") }, "unmapped account")
        XCTAssertEqual(all.map(\.date), all.map(\.date).sorted(by: >))
        XCTAssertLessThan(elapsed, 5)

        // Inbox membership vs. Mail's own INBOX counter (mailboxes.total_count) per account.
        var inbox: [String: Int] = [:]
        for m in all where m.inInbox { inbox[m.mailbox.account, default: 0] += 1 }
        let db = try src.openIndex()
        var mailCounts: [String: Int] = [:]
        let emails = AppleAccounts.emailsByUUID(accountsDB: src.accountsDB)
        try db.query("select ROWID, url, total_count from mailboxes") { r in
            guard let mb = AppleMailbox(id: r.int(0), url: r.text(1) ?? ""), mb.role == .inbox, mb.scheme != "local" else { return }
            mailCounts[emails[mb.accountUUID] ?? mb.accountUUID, default: 0] += Int(r.int(2))
        }
        print("inbox: ours \(inbox.sorted { $0.key < $1.key }); Mail total_count \(mailCounts.sorted { $0.key < $1.key })")
        for (account, n) in inbox { XCTAssertEqual(Double(n), Double(mailCounts[account] ?? 0), accuracy: max(5, Double(n) * 0.01), account) }
    }

    func testListMailboxTrashAndSpam() throws {
        let src = try realSource()
        let trash = try src.listMailbox(.trash), spam = try src.listMailbox(.spam)
        print("trash: \(trash.count), spam: \(spam.count)")
        XCTAssertTrue(trash.allSatisfy { $0.mailbox.role == .trash && !$0.inInbox })
        XCTAssertTrue(spam.allSatisfy { $0.mailbox.role == .spam && !$0.inInbox })
        XCTAssertEqual(try src.listMailbox(.sent), [])
        // restore moves Trash and Spam messages to their account's INBOX (planned only; nothing runs).
        if let t = trash.first, let j = spam.first {
            let plan = try src.plan(.restore, ids: [t.id, j.id])
            XCTAssertTrue(plan.noop.isEmpty && plan.failed.isEmpty)
            XCTAssertEqual(Set(plan.jobs.flatMap(\.ids)), [t.id, j.id])
            XCTAssertTrue(plan.jobs.allSatisfy { $0.target?.path == "INBOX" })
            XCTAssertEqual(Set(plan.jobs.map { MailboxRoles.role(forPath: $0.source.path) }), [.trash, .spam])
        }
        // junk moves an inbox message to its account's Spam mailbox, and is a no-op on mail already in Spam.
        if let m = try src.listMessages().first(where: \.inInbox), let j = spam.first {
            let plan = try src.plan(.junk, ids: [m.id, j.id])
            XCTAssertEqual(plan.noop, [j.id])
            XCTAssertEqual(plan.jobs.flatMap(\.ids), [m.id])
            XCTAssertEqual(plan.jobs.first.flatMap { MailboxRoles.role(forPath: $0.target?.path ?? "") }, .spam)
        }
        let searchable = Set(try src.listMessages().map(\.id))
        XCTAssertTrue(searchable.isDisjoint(with: trash.map(\.id)) && searchable.isDisjoint(with: spam.map(\.id)))
    }

    func testParseSamplesOnRealStore() throws {
        let src = try realSource()
        let all = try src.listMessages()
        let sample = stride(from: 0, to: all.count, by: max(1, all.count / 300)).map { all[$0] }
        let t0 = Date()
        var empty = 0, subjectSame = 0
        for m in sample {
            let p = try src.parse(m)
            let fileSubject = try XCTUnwrap(try AppleMailSource.parseFile(path: try XCTUnwrap(src.messageFiles()[m.id]))).subject
            if AppleMailGoldenTests.collapse(fileSubject) == AppleMailGoldenTests.collapse(m.subject) { subjectSame += 1 }
            if p.bodyText.isEmpty { empty += 1; print("empty body: \(m.id)") }
        }
        let per = Date().timeIntervalSince(t0) / Double(sample.count) * 1000
        print("parse: \(sample.count) messages, \(String(format: "%.1f", per)) ms each, \(empty) empty bodies, index subject == header subject: \(subjectSame)")
        XCTAssertLessThan(Double(empty) / Double(sample.count), 0.05)
    }

    func testConcurrentParse() async throws {
        let src = try realSource()
        let sample = Array(try src.listMessages().prefix(500))
        let fresh = AppleMailSource()   // cold cache: concurrent misses must share one walk
        let bodies = try await withThrowingTaskGroup(of: (Int64, String).self) { group in
            for m in sample { group.addTask { (m.id, try fresh.parse(m).bodyText) } }
            return try await group.reduce(into: [Int64: String]()) { $0[$1.0] = $1.1 }
        }
        XCTAssertEqual(bodies.count, sample.count)
        for m in sample.prefix(50) { XCTAssertEqual(bodies[m.id], try src.parse(m).bodyText) }
    }

    func testPlanOnRealStore() throws {
        let src = try realSource()
        let db = try src.openIndex()
        let boxes = try src.mailboxes(db)
        // A Gmail message carrying the INBOX label, and one that doesn't.
        var labelled: Int64?, unlabelled: Int64?
        try db.query("""
            select m.ROWID, m.mailbox, exists(select 1 from labels l where l.message_id = m.ROWID and l.mailbox_id in
                (select ROWID from mailboxes where url like '%/INBOX'))
            from messages m where m.deleted = 0 order by m.ROWID desc limit 5000
            """) { r in
            guard boxes[r.int(1)]?.role == .allMail else { return }
            if r.int(2) == 1 { if labelled == nil { labelled = r.int(0) } } else if unlabelled == nil { unlabelled = r.int(0) }
        }
        guard let labelled, let unlabelled else { throw XCTSkip("no Gmail sample") }

        let plan = try src.plan(.archive, ids: [labelled, unlabelled, 999_999_999])
        XCTAssertEqual(plan.noop, [unlabelled])
        XCTAssertNotNil(plan.failed[999_999_999])
        XCTAssertEqual(plan.jobs.count, 1)
        XCTAssertEqual(plan.jobs.first?.source.path, "INBOX")
        XCTAssertEqual(plan.jobs.first.flatMap { $0.target.map { MailboxRoles.role(forPath: $0.path) } }, .allMail)
        XCTAssertEqual(plan.jobs.first?.ids, [labelled])

        let read = try src.plan(.markRead, ids: [labelled, unlabelled])
        XCTAssertEqual(read.jobs.flatMap(\.ids).sorted(), [labelled, unlabelled].sorted())
        XCTAssertTrue(read.jobs.allSatisfy { MailboxRoles.role(forPath: $0.source.path) == .allMail })
    }

    /// perform() with a fake script runner: nothing reaches Mail.
    func testPerformWithFakeRunner() async throws {
        let real = try realSource()
        let ids = try real.listMessages().prefix(3).map(\.id)
        guard ids.count == 3 else { throw XCTSkip("too few messages") }
        let scripts = ScriptLog()
        let src = AppleMailSource(runScript: { script in
            await scripts.append(script)
            return "\(ids[1])\t-1728 Can’t get message.\n"
        })
        let report = try await src.perform(.flag, on: ids + [999_999_999])
        XCTAssertEqual(Set(report.succeeded), Set([ids[0], ids[2]]))
        XCTAssertEqual(Set(report.failed.keys), Set([ids[1], 999_999_999]))
        let sent = await scripts.all
        XCTAssertFalse(sent.isEmpty)
        XCTAssertTrue(sent.allSatisfy { $0.contains("set flagged status of") })

        // A failing script fails its own ids but keeps the report.
        let flaky = AppleMailSource(runScript: { _ in throw MailSourceError.other("Mail busy") })
        let partial = try await flaky.perform(.flag, on: ids)
        XCTAssertEqual(Set(partial.failed.keys), Set(ids))

        let denied = AppleMailSource(runScript: { _ in throw MailSourceError.automationDenied })
        do { _ = try await denied.perform(.markRead, on: ids); XCTFail("expected throw") } catch MailSourceError.automationDenied {}
    }
}

private actor ScriptLog {
    var all: [String] = []
    func append(_ s: String) { all.append(s) }
}
