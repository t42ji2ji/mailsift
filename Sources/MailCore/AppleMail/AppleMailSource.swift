import Foundation

/// Reads Apple Mail's local store (~/Library/Mail/V*/) and acts on mail by scripting Mail.app.
///
/// Gmail accounts keep one `messages` row per message, in All Mail; label membership (INBOX, user labels) lives in
/// the `labels` table. Other IMAP accounts have one row per message per folder.
public final class AppleMailSource: MailSource, @unchecked Sendable {
    public let name = "Apple Mail"

    let libraryMail: URL
    let accountsDB: String
    let runScript: @Sendable (String) async throws -> String

    private let lock = NSLock()
    private let scanLock = NSLock()
    private var cachedFiles: [Int64: String]?
    private var scannedAt = Date.distantPast

    /// - Parameters:
    ///   - libraryMail: `~/Library/Mail`; the newest `V<n>` directory inside is used.
    ///   - runScript: executes AppleScript source and returns its result (injectable for tests).
    let cachesRoot: URL

    public init(libraryMail: URL? = nil, accountsDB: String? = nil, cachesRoot: URL? = nil,
                runScript: (@Sendable (String) async throws -> String)? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.libraryMail = libraryMail ?? home.appendingPathComponent("Library/Mail")
        self.accountsDB = accountsDB ?? home.appendingPathComponent("Library/Accounts/Accounts4.sqlite").path
        self.runScript = runScript ?? { try await MailScriptRunner.run($0) }
        self.cachesRoot = cachesRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailSift/attachments", isDirectory: true)
    }

    // MARK: Store layout

    /// The newest `V<n>` directory that has an Envelope Index.
    func storeRoot() throws -> URL {
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: libraryMail.path) } catch {
            // ~/Library/Mail exists on every Mac; failing to list it means TCC denied us.
            throw MailSourceError.fullDiskAccessRequired
        }
        let versions = names.compactMap { n -> Int? in n.hasPrefix("V") ? Int(n.dropFirst()) : nil }.sorted(by: >)
        for v in versions {
            let root = libraryMail.appendingPathComponent("V\(v)")
            if fm.fileExists(atPath: root.appendingPathComponent("MailData/Envelope Index").path) { return root }
        }
        throw MailSourceError.other("No Apple Mail data found in \(libraryMail.path). Set up an account in Mail first.")
    }

    func openIndex() throws -> ReadOnlySQLite {
        try ReadOnlySQLite(path: storeRoot().appendingPathComponent("MailData/Envelope Index").path)
    }

    func mailboxes(_ db: ReadOnlySQLite) throws -> [Int64: AppleMailbox] {
        var out: [Int64: AppleMailbox] = [:]
        try db.query("select ROWID, url from mailboxes") { row in
            if let url = row.text(1), let mb = AppleMailbox(id: row.int(0), url: url) { out[mb.id] = mb }
        }
        return out
    }

    /// Message ROWID → .emlx path, from one walk of the store. A full .emlx wins over a .partial.emlx.
    /// Safe to call concurrently: the map is an immutable value behind `lock`, and walks are serialized by `scanLock`
    /// so concurrent cache misses wait for one walk instead of starting their own.
    func messageFiles(refresh: Bool = false) throws -> [Int64: String] {
        lock.lock()
        if !refresh, let c = cachedFiles { lock.unlock(); return c }
        let requestedAt = Date()
        lock.unlock()
        scanLock.lock()
        defer { scanLock.unlock() }
        lock.lock()
        if let c = cachedFiles, scannedAt >= requestedAt || (!refresh) { lock.unlock(); return c }  // another caller just scanned
        lock.unlock()
        let files = try MessageFiles.scan(root: storeRoot())
        lock.lock(); cachedFiles = files; scannedAt = Date(); lock.unlock()
        return files
    }

    /// The cached map, rescanned when `id` is missing unless a scan ran in the last 30 s (new mail arrives rarely;
    /// a message trashed mid-index must not trigger a full walk per message).
    private func messageFile(_ id: Int64) throws -> String? {
        let files = try messageFiles()
        if let p = files[id] { return p }
        lock.lock(); let recent = Date().timeIntervalSince(scannedAt) < 30; lock.unlock()
        return recent ? nil : try messageFiles(refresh: true)[id]
    }

    // MARK: MailSource

    public func checkAccess() throws {
        let db = try openIndex()
        try db.query("select count(*) from mailboxes") { _ in }
    }

    public func listMessages() throws -> [MessageMeta] {
        try list { !MailboxRoles.isExcluded($0) }
    }

    /// Messages in Trash or Spam; other roles return [] (the library derives inbox/archive from `inInbox`).
    public func listMailbox(_ role: MailboxRole) throws -> [MessageMeta] {
        guard role == .trash || role == .spam else { return [] }
        return try list { $0.role == role }
    }

    private func list(_ include: (AppleMailbox) -> Bool) throws -> [MessageMeta] {
        let db = try openIndex()
        let boxes = try mailboxes(db)
        let emails = AppleAccounts.emailsByUUID(accountsDB: accountsDB)
        let files = try messageFiles(refresh: true)

        var refs: [Int64: MailboxRef] = [:]
        for (id, mb) in boxes where include(mb) {
            let account = mb.scheme == "local" ? "On My Mac" : emails[mb.accountUUID] ?? mb.accountUUID
            refs[id] = MailboxRef(id: id, account: account, name: mb.path, role: mb.role)
        }
        let gmailAccounts = Set(boxes.values.filter(\.isGmailSystem).map(\.accountUUID))

        // Gmail keeps INBOX membership as a label on the All Mail row; one query for all of them.
        var inboxLabelled = Set<Int64>()
        let inboxBoxes = boxes.values.filter { $0.role == .inbox && gmailAccounts.contains($0.accountUUID) }.map(\.id)
        if !inboxBoxes.isEmpty {
            try db.query("select message_id from labels where mailbox_id in (\(inboxBoxes.map(String.init).joined(separator: ",")))") {
                inboxLabelled.insert($0.int(0))
            }
        }

        struct Row { var meta: MessageMeta; var gid: Int64; var account: String }
        var rows: [Row] = []
        rows.reserveCapacity(files.count)
        try db.query("""
            select m.ROWID, m.mailbox, m.date_received, m.subject_prefix, s.subject, a.address, a.comment,
                   m.read, m.flagged, m.global_message_id
            from messages m
            left join subjects s on s.ROWID = m.subject
            left join addresses a on a.ROWID = m.sender
            where m.deleted = 0
            order by m.date_received desc, m.ROWID desc
            """) { r in
            let id = r.int(0)
            guard let ref = refs[r.int(1)], let mb = boxes[r.int(1)], files[id] != nil else { return }
            let inInbox: Bool
            switch mb.role {
            case .trash, .spam, .drafts: inInbox = false
            default: inInbox = mb.scheme != "local" && (mb.role == .inbox || inboxLabelled.contains(id))
            }
            let meta = MessageMeta(
                id: id, mailbox: ref, date: Date(timeIntervalSince1970: r.double(2)),
                subject: (r.text(3) ?? "") + (r.text(4) ?? ""),
                senderAddress: (r.text(5) ?? "").lowercased(), senderName: r.text(6) ?? "",
                isRead: r.int(7) != 0, isFlagged: r.int(8) != 0, inInbox: inInbox)
            rows.append(Row(meta: meta, gid: r.int(9), account: mb.accountUUID))
        }

        // Gmail: a message seen in All Mail and in a label mailbox is listed once, from All Mail.
        var inAllMail = Set<String>()
        for row in rows where gmailAccounts.contains(row.account) && row.meta.mailbox.role == .allMail && row.gid != 0 {
            inAllMail.insert("\(row.account)|\(row.gid)")
        }
        return rows.filter { row in
            guard gmailAccounts.contains(row.account), row.meta.mailbox.role != .allMail, row.gid != 0 else { return true }
            return !inAllMail.contains("\(row.account)|\(row.gid)")
        }.map(\.meta)
    }

    public func parse(_ meta: MessageMeta) throws -> ParsedMessage {
        guard let path = try messageFile(meta.id) else { throw MailSourceError.messageFileMissing(meta.id) }
        let parsed = try AppleMailSource.parseFile(path: path, id: meta.id)
        guard let parsed else { throw MailSourceError.messageFileMissing(meta.id) }
        var m = meta
        if m.subject.isEmpty { m.subject = parsed.subject }
        if m.senderAddress.isEmpty, let f = parsed.from { m.senderAddress = f.address.lowercased(); m.senderName = f.name }
        return ParsedMessage(meta: m, to: parsed.to.map(Self.format), cc: parsed.cc.map(Self.format),
                             bodyText: parsed.bodyText, html: parsed.html, attachments: parsed.attachments)
    }

    /// Mail's own saved copy when it has one; otherwise the part decoded from the .emlx into
    /// ~/Library/Caches/MailSift/attachments/<id>/<part>/ (written once, reused).
    public func attachmentFile(_ meta: MessageMeta, _ attachment: Attachment) throws -> URL {
        guard let path = try messageFile(meta.id) else { throw MailSourceError.messageFileMissing(meta.id) }
        let mailDir = MailAttachments.attachmentsDir(forEmlx: path, id: meta.id)
        if let f = MailAttachments.diskFile(in: mailDir, part: attachment.part) { return f }

        let cacheDir = cachesRoot.appendingPathComponent("\(meta.id)/\(attachment.part)", isDirectory: true)
        let target = cacheDir.appendingPathComponent(MailAttachments.sanitize(attachment.filename))
        if FileManager.default.fileExists(atPath: target.path) { return target }

        guard let data = FileManager.default.contents(atPath: path) else { throw MailSourceError.messageFileMissing(meta.id) }
        let root = MIME.parse(Emlx.messageBytes(data))
        guard let part = MailAttachments.part(root, number: attachment.part), MailAttachments.hasBody(part) else {
            throw MailSourceError.other("Not downloaded by Mail yet")
        }
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try Data(part.decodedBody).write(to: target, options: .atomic)
        } catch {
            throw MailSourceError.other("Cannot save attachment: \(error.localizedDescription)")
        }
        return target
    }

    public func downloadAttachment(_ meta: MessageMeta, _ attachment: Attachment) async throws -> URL {
        let db = try openIndex()
        let boxes = try mailboxes(db)
        var box: AppleMailbox?
        try db.query("select mailbox from messages where ROWID = ? and deleted = 0", [meta.id]) { box = boxes[$0.int(0)] }
        guard let box else { throw MailSourceError.messageFileMissing(meta.id) }
        let spec = MailScript.MailboxSpec(accountUUID: box.scheme == "local" ? nil : box.accountUUID, path: box.path)

        let dir = cachesRoot.appendingPathComponent("\(meta.id)/\(attachment.part)", isDirectory: true)
        let target = dir.appendingPathComponent(MailAttachments.sanitize(attachment.filename))
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            throw MailSourceError.other("Cannot save attachment: \(error.localizedDescription)")
        }
        // `filename` may carry an extension Mail's name lacks (added from the MIME type).
        let names = [attachment.filename, (attachment.filename as NSString).deletingPathExtension]
        _ = try await runScript(MailScript.saveAttachment(id: meta.id, in: spec, names: names, to: target.path))
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw MailSourceError.other("Mail could not download \(attachment.filename)")
        }
        return target
    }

    static func format(_ a: MIME.Address) -> String {
        a.name.isEmpty || a.name == a.address ? a.address : "\(a.name) <\(a.address)>"
    }

    struct FileParse {
        var subject: String
        var from: MIME.Address?
        var to: [MIME.Address]
        var cc: [MIME.Address]
        var bodyText: String
        var html: String?
        var attachments: [Attachment]
    }

    /// Parses one .emlx file. Returns nil when the file is gone.
    /// `id` locates Mail's saved attachments next to the Messages folder; pass nil to skip that check.
    static func parseFile(path: String, id: Int64? = nil) throws -> FileParse? {
        guard let data = FileManager.default.contents(atPath: path) else {
            if FileManager.default.fileExists(atPath: path) { throw MailSourceError.fullDiskAccessRequired }
            return nil
        }
        let root = MIME.parse(Emlx.messageBytes(data))
        let body = MailText.body(of: root)
        let subject = MIME.decodeHeader(root.header("subject") ?? "")
        return FileParse(
            subject: MailText.normalize(subject).split(separator: "\n").joined(separator: " "),
            from: MIME.parseAddresses(root.header("from") ?? "").first,
            to: MIME.parseAddresses(root.header("to") ?? ""),
            cc: MIME.parseAddresses(root.header("cc") ?? ""),
            bodyText: body.text, html: body.html,
            attachments: MailAttachments.list(root, attachmentsDir: id.map { MailAttachments.attachmentsDir(forEmlx: path, id: $0) }))
    }

    // MARK: Actions

    struct Located { var id: Int64; var mailbox: AppleMailbox }

    public func perform(_ action: MailAction, on ids: [Int64]) async throws -> ActionReport {
        let plan = try plan(action, ids: ids)
        var succeeded = plan.noop
        var failed = plan.failed
        for job in plan.jobs {
            for chunk in stride(from: 0, to: job.ids.count, by: 200).map({ Array(job.ids[$0..<min($0 + 200, job.ids.count)]) }) {
                // Earlier chunks may already have changed mail, so only a permission error aborts the whole call.
                let out: String
                do {
                    out = try await runScript(MailScript.script(action, ids: chunk, source: job.source, target: job.target))
                } catch MailSourceError.automationDenied {
                    throw MailSourceError.automationDenied
                } catch {
                    for id in chunk { failed[id] = error.localizedDescription }
                    continue
                }
                let f = MailScript.failures(fromOutput: out)
                for id in chunk { if let e = f[id] { failed[id] = e } else { succeeded.append(id) } }
            }
        }
        return ActionReport(action: action, succeeded: succeeded, failed: failed)
    }

    struct Job: Equatable { var source: MailScript.MailboxSpec; var target: MailScript.MailboxSpec?; var ids: [Int64] }
    struct Plan { var jobs: [Job]; var noop: [Int64]; var failed: [Int64: String] }

    /// Resolves ids against the Envelope Index and groups them into scripts. No Mail.app calls.
    func plan(_ action: MailAction, ids: [Int64]) throws -> Plan {
        let db = try openIndex()
        let boxes = try mailboxes(db)
        var located: [Int64: AppleMailbox] = [:]
        var inInbox = Set<Int64>()   // Gmail: messages carrying the INBOX label
        let unique = Array(NSOrderedSet(array: ids)) as! [Int64]
        for start in stride(from: 0, to: unique.count, by: 500) {
            let chunk = unique[start..<min(start + 500, unique.count)]
            let list = chunk.map(String.init).joined(separator: ",")
            try db.query("select ROWID, mailbox from messages where ROWID in (\(list)) and deleted = 0") { r in
                if let mb = boxes[r.int(1)] { located[r.int(0)] = mb }
            }
            if action == .archive {
                try db.query("select message_id, mailbox_id from labels where message_id in (\(list))") { r in
                    if boxes[r.int(1)]?.role == .inbox { inInbox.insert(r.int(0)) }
                }
            }
        }

        var failed: [Int64: String] = [:]
        var noop: [Int64] = []
        var groups: [String: Job] = [:]
        var order: [String] = []
        func spec(_ mb: AppleMailbox) -> MailScript.MailboxSpec {
            MailScript.MailboxSpec(accountUUID: mb.scheme == "local" ? nil : mb.accountUUID, path: mb.path)
        }
        func add(_ id: Int64, _ source: MailScript.MailboxSpec, _ target: MailScript.MailboxSpec?) {
            let key = "\(source)|\(String(describing: target))"
            if groups[key] == nil { groups[key] = Job(source: source, target: target, ids: []); order.append(key) }
            groups[key]!.ids.append(id)
        }
        let byAccount = Dictionary(grouping: boxes.values, by: \.accountUUID)

        for id in unique {
            guard let mb = located[id] else { failed[id] = "Message not found in Mail's index."; continue }
            switch action {
            case .trash:
                if mb.role == .trash { noop.append(id) } else { add(id, spec(mb), nil) }
            case .archive:
                let siblings = byAccount[mb.accountUUID] ?? []
                if mb.isGmailSystem || siblings.contains(where: \.isGmailSystem) {
                    // Gmail: archiving removes the INBOX label, i.e. moves the inbox copy to All Mail.
                    guard inInbox.contains(id) || mb.role == .inbox else { noop.append(id); continue }
                    guard let inbox = siblings.first(where: { $0.role == .inbox }),
                          let all = siblings.first(where: { $0.role == .allMail }) else {
                        failed[id] = "No INBOX or All Mail mailbox for this Gmail account."; continue
                    }
                    add(id, spec(inbox), spec(all))
                } else {
                    if mb.role == .archive { noop.append(id); continue }
                    guard let archive = siblings.first(where: { $0.role == .archive }) else {
                        failed[id] = "This account has no Archive mailbox."; continue
                    }
                    add(id, spec(mb), spec(archive))
                }
            case .restore:
                // Out of Trash, or out of Spam ("not junk"): back to the account's INBOX.
                guard mb.role == .trash || mb.role == .spam else { noop.append(id); continue }
                guard let inbox = (byAccount[mb.accountUUID] ?? []).first(where: { $0.role == .inbox }) else {
                    failed[id] = "This account has no INBOX mailbox."; continue
                }
                add(id, spec(mb), spec(inbox))
            case .markRead, .markUnread, .flag, .unflag:
                add(id, spec(mb), nil)
            }
        }
        return Plan(jobs: order.map { groups[$0]! }, noop: noop, failed: failed)
    }
}

/// .emlx: a decimal byte count line, that many bytes of RFC 822 message, then an Apple plist.
enum Emlx {
    static func messageBytes(_ data: Data) -> ArraySlice<UInt8> {
        let bytes = [UInt8](data)
        guard let nl = bytes.firstIndex(of: 0x0A),
              let n = Int(String(decoding: bytes[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)) else {
            return bytes[...]
        }
        let start = nl + 1
        return bytes[start..<min(bytes.count, start + n)]
    }
}

enum MessageFiles {
    /// Walks `root` for `…/Messages/<ROWID>[.partial].emlx`.
    static func scan(root: URL) throws -> [Int64: String] {
        var out: [Int64: String] = [:]
        guard let e = FileManager.default.enumerator(atPath: root.path) else {
            throw MailSourceError.fullDiskAccessRequired
        }
        let base = root.path + "/"
        while let rel = e.nextObject() as? String {
            if rel == "MailData" || rel.hasSuffix("/Attachments") { e.skipDescendants(); continue }
            guard rel.hasSuffix(".emlx") else { continue }
            let name = (rel as NSString).lastPathComponent
            let partial = name.hasSuffix(".partial.emlx")
            guard let dot = name.firstIndex(of: "."), let id = Int64(name[..<dot]) else { continue }
            if partial, out[id] != nil { continue }
            out[id] = base + rel
        }
        return out
    }
}
