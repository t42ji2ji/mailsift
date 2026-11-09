import Foundation

/// The on-disk index: message metadata + body text, a trigram FTS5 table over it, and Float16 vectors.
/// Three connections in WAL mode, so searches read while the indexer writes and list browsing never queues behind
/// either; each connection has its own lock.
final class IndexStore: @unchecked Sendable {
    /// Bodies are stored up to this many characters for keyword search; the reader view re-parses the source.
    static let maxStoredBody = 20_000

    private let writer: SQLiteConnection
    private let reader: SQLiteConnection
    private let browser: SQLiteConnection
    private let writeLock = NSLock()
    private let readLock = NSLock()
    private let browseLock = NSLock()

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try SQLiteConnection(url: url)
        try writer.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try writer.execute(Self.schema)
        var columns = Set<String>()
        try writer.query("PRAGMA table_info(messages)") { columns.insert($0.text(1)) }
        if !columns.contains("in_inbox") {
            try writer.execute("ALTER TABLE messages ADD COLUMN in_inbox INTEGER NOT NULL DEFAULT 1")
        }
        reader = try SQLiteConnection(url: url)
        browser = try SQLiteConnection(url: url)
    }

    /// detail=none: no token positions, about a quarter of the size. Phrases can't be matched, so a term's trigrams
    /// are ANDed and the term itself is checked against the text (`keywordSearch`).
    private static let ftsColumns = """
        subject, sender_name, sender_address, body, content='messages', content_rowid='id', tokenize='trigram', detail=none
        """

    private static let schema = """
        CREATE TABLE IF NOT EXISTS messages(
            id INTEGER PRIMARY KEY, account TEXT NOT NULL, mailbox_id INTEGER NOT NULL, mailbox_name TEXT NOT NULL,
            mailbox_role TEXT NOT NULL, date REAL NOT NULL, subject TEXT NOT NULL, sender_address TEXT NOT NULL,
            sender_name TEXT NOT NULL, is_read INTEGER NOT NULL, is_flagged INTEGER NOT NULL, body TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS messages_date ON messages(date DESC);
        CREATE INDEX IF NOT EXISTS messages_sender ON messages(sender_address COLLATE NOCASE, account);
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(\(ftsColumns));
        CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
            INSERT INTO messages_fts(rowid, subject, sender_name, sender_address, body)
            VALUES (new.id, new.subject, new.sender_name, new.sender_address, new.body);
        END;
        CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
            INSERT INTO messages_fts(messages_fts, rowid, subject, sender_name, sender_address, body)
            VALUES ('delete', old.id, old.subject, old.sender_name, old.sender_address, old.body);
        END;
        CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF subject, sender_name, sender_address, body ON messages BEGIN
            INSERT INTO messages_fts(messages_fts, rowid, subject, sender_name, sender_address, body)
            VALUES ('delete', old.id, old.subject, old.sender_name, old.sender_address, old.body);
            INSERT INTO messages_fts(rowid, subject, sender_name, sender_address, body)
            VALUES (new.id, new.subject, new.sender_name, new.sender_address, new.body);
        END;
        -- seq only grows (AUTOINCREMENT), so readers can load new vectors incrementally.
        CREATE TABLE IF NOT EXISTS vectors(
            seq INTEGER PRIMARY KEY AUTOINCREMENT, id INTEGER NOT NULL UNIQUE, vec BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS categories(id INTEGER PRIMARY KEY, category TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS categories_category ON categories(category);
        CREATE TABLE IF NOT EXISTS category_definitions(
            position INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, name TEXT NOT NULL, description TEXT NOT NULL,
            hidden INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """

    private func write<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        return try body(writer)
    }

    private func read<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        readLock.lock()
        defer { readLock.unlock() }
        return try body(reader)
    }

    private func browse<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        browseLock.lock()
        defer { browseLock.unlock() }
        return try body(browser)
    }

    /// Rebuilds a keyword index made by earlier versions (with positions) as detail=none, then compacts the file so
    /// the space is returned. Searches keep working on either.
    func upgradeKeywordIndex() throws {
        try write { db in
            var sql = ""
            try db.query("SELECT sql FROM sqlite_master WHERE name = 'messages_fts'") { sql = $0.text(0) }
            guard !sql.contains("detail=none") else { return }
            try db.transaction {
                try db.execute("""
                    DROP TABLE messages_fts;
                    CREATE VIRTUAL TABLE messages_fts USING fts5(\(Self.ftsColumns));
                    INSERT INTO messages_fts(messages_fts) VALUES('rebuild');
                    """)
            }
            try db.execute("VACUUM")
        }
    }

    // MARK: - Writes

    func upsert(_ messages: [ParsedMessage]) throws {
        try write { db in
            try db.transaction {
                let statement = try db.prepare("""
                    INSERT INTO messages(id, account, mailbox_id, mailbox_name, mailbox_role, date, subject,
                        sender_address, sender_name, is_read, is_flagged, body, in_inbox)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET account=excluded.account, mailbox_id=excluded.mailbox_id,
                        mailbox_name=excluded.mailbox_name, mailbox_role=excluded.mailbox_role, date=excluded.date,
                        subject=excluded.subject, sender_address=excluded.sender_address,
                        sender_name=excluded.sender_name, is_read=excluded.is_read, is_flagged=excluded.is_flagged,
                        body=excluded.body, in_inbox=excluded.in_inbox
                    """)
                for message in messages {
                    let m = message.meta
                    try statement.run([
                        .int(m.id), .text(m.mailbox.account), .int(m.mailbox.id), .text(m.mailbox.name),
                        .text(m.mailbox.role.rawValue), .double(m.date.timeIntervalSince1970), .text(m.subject),
                        .text(m.senderAddress), .text(m.senderName), .int(m.isRead ? 1 : 0), .int(m.isFlagged ? 1 : 0),
                        .text(String(message.bodyText.prefix(Self.maxStoredBody))), .int(m.inInbox ? 1 : 0),
                    ])
                }
            }
        }
    }

    /// Refreshes fields that change without a new message (read/flag state, mailbox after archive). Text is kept.
    func updateMeta(_ metas: [MessageMeta]) throws {
        try write { db in
            try db.transaction {
                let statement = try db.prepare("""
                    UPDATE messages SET account=?, mailbox_id=?, mailbox_name=?, mailbox_role=?, date=?, is_read=?,
                        is_flagged=?, in_inbox=? WHERE id=?
                    """)
                for m in metas {
                    try statement.run([
                        .text(m.mailbox.account), .int(m.mailbox.id), .text(m.mailbox.name),
                        .text(m.mailbox.role.rawValue), .double(m.date.timeIntervalSince1970), .int(m.isRead ? 1 : 0),
                        .int(m.isFlagged ? 1 : 0), .int(m.inInbox ? 1 : 0), .int(m.id),
                    ])
                }
            }
        }
    }

    func setFlags(_ ids: [Int64], isRead: Bool? = nil, isFlagged: Bool? = nil, inInbox: Bool? = nil) throws {
        try write { db in
            try db.transaction {
                let statement = try db.prepare(
                    "UPDATE messages SET is_read=coalesce(?, is_read), is_flagged=coalesce(?, is_flagged), in_inbox=coalesce(?, in_inbox) WHERE id=?")
                for id in ids {
                    try statement.run([
                        isRead.map { .int($0 ? 1 : 0) } ?? .null, isFlagged.map { .int($0 ? 1 : 0) } ?? .null,
                        inInbox.map { .int($0 ? 1 : 0) } ?? .null, .int(id),
                    ])
                }
            }
        }
    }

    /// Removes messages, their FTS rows (trigger) and their vectors.
    func delete(_ ids: [Int64]) throws {
        try write { db in
            try db.transaction {
                let messages = try db.prepare("DELETE FROM messages WHERE id=?")
                let vectors = try db.prepare("DELETE FROM vectors WHERE id=?")
                let categories = try db.prepare("DELETE FROM categories WHERE id=?")
                for id in ids {
                    try messages.run([.int(id)])
                    try vectors.run([.int(id)])
                    try categories.run([.int(id)])
                }
            }
        }
    }

    /// Stores L2-normalized vectors as Float16. Ids no longer in `messages` are skipped.
    func setVectors(_ vectors: [(id: Int64, vector: [Float])]) throws {
        try write { db in
            try db.transaction {
                let statement = try db.prepare(
                    "INSERT OR REPLACE INTO vectors(id, vec) SELECT ?1, ?2 WHERE EXISTS(SELECT 1 FROM messages WHERE id=?1)")
                for (id, vector) in vectors {
                    let half = vector.map { Float16($0) }
                    try statement.run([.int(id), .blob(half.withUnsafeBytes { Data($0) })])
                }
            }
        }
    }

    /// Replaces every message's category.
    func setCategories(_ labels: [Int64: String]) throws {
        try write { db in
            try db.transaction {
                try db.execute("DELETE FROM categories")
                let statement = try db.prepare("INSERT INTO categories(id, category) VALUES (?, ?)")
                for (id, category) in labels { try statement.run([.int(id), .text(category)]) }
            }
        }
    }

    func setCategoryDefinitions(_ categories: [MailCategory]) throws {
        try write { db in
            try db.transaction {
                try db.execute("DELETE FROM category_definitions")
                let statement = try db.prepare("INSERT INTO category_definitions(position, id, name, description, hidden) VALUES (?, ?, ?, ?, ?)")
                for (i, c) in categories.enumerated() {
                    try statement.run([.int(Int64(i)), .text(c.id), .text(c.name), .text(c.description), .int(c.hidden ? 1 : 0)])
                }
            }
        }
    }

    func setSetting(_ key: String, _ value: String) throws {
        try write { db in
            try db.prepare("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)").run([.text(key), .text(value)])
        }
    }

    // MARK: - Reads

    func categoryDefinitions() throws -> [MailCategory] {
        try read { db in
            var out: [MailCategory] = []
            try db.query("SELECT id, name, description, hidden FROM category_definitions ORDER BY position") {
                out.append(MailCategory(id: $0.text(0), name: $0.text(1), description: $0.text(2), hidden: $0.int(3) != 0))
            }
            return out
        }
    }

    func setting(_ key: String) throws -> String? {
        try read { db in
            var value: String?
            try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { value = $0.text(0) }
            return value
        }
    }

    /// Category ids in use.
    func categoryIDs() throws -> Set<String> {
        try read { db in
            var ids = Set<String>()
            try db.query("SELECT DISTINCT category FROM categories") { ids.insert($0.text(0)) }
            return ids
        }
    }

    /// Messages per category in `box`.
    func categoryCounts(_ box: BrowseBox, accounts: [String]?) throws -> [String: Int] {
        let only = Self.whereClause(SearchFilter(accounts: accounts))
        return try read { db in
            var counts: [String: Int] = [:]
            try db.query(
                "SELECT c.category, count(*) FROM messages m JOIN categories c ON c.id = m.id WHERE \(Self.boxCondition(box)) AND \(only.sql) GROUP BY c.category",
                only.args) { counts[$0.text(0)] = Int($0.int(1)) }
            return counts
        }
    }

    func allIDs() throws -> Set<Int64> {
        try read { db in
            var ids = Set<Int64>()
            try db.query("SELECT id FROM messages") { ids.insert($0.int(0)) }
            return ids
        }
    }

    func counts() throws -> (messages: Int, vectors: Int) {
        try read { db in
            var counts = (messages: 0, vectors: 0)
            try db.query("SELECT (SELECT count(*) FROM messages), (SELECT count(*) FROM vectors)") {
                counts = (Int($0.int(0)), Int($0.int(1)))
            }
            return counts
        }
    }

    /// Messages without a vector, newest first.
    func idsMissingVectors() throws -> [Int64] {
        try read { db in
            var ids: [Int64] = []
            try db.query("""
                SELECT m.id FROM messages m LEFT JOIN vectors v ON v.id = m.id WHERE v.id IS NULL ORDER BY m.date DESC
                """) { ids.append($0.int(0)) }
            return ids
        }
    }

    /// Messages whose vector was stored at or before `seq` (made from an older document text), newest first.
    func idsWithVectors(upTo seq: Int64) throws -> [Int64] {
        try read { db in
            var ids: [Int64] = []
            try db.query("SELECT m.id FROM vectors v JOIN messages m ON m.id = v.id WHERE v.seq <= ? ORDER BY m.date DESC",
                         [.int(seq)]) { ids.append($0.int(0)) }
            return ids
        }
    }

    /// Subject and body for embedding, in the order of `ids` (missing ids are dropped).
    func documents(_ ids: [Int64]) throws -> [(id: Int64, subject: String, body: String)] {
        try read { db in
            var found: [Int64: (subject: String, body: String)] = [:]
            let statement = try db.prepare("SELECT subject, body FROM messages WHERE id=?")
            for id in ids {
                try statement.bind([.int(id)])
                if try statement.step() { found[id] = (statement.text(0), statement.text(1)) }
            }
            return ids.compactMap { id in found[id].map { (id, $0.subject, $0.body) } }
        }
    }

    private static let metaColumns = """
        m.id, m.account, m.mailbox_id, m.mailbox_name, m.mailbox_role, m.date, m.subject, m.sender_address,
        m.sender_name, m.is_read, m.is_flagged, m.in_inbox
        """

    private static func meta(_ s: Statement) -> MessageMeta {
        MessageMeta(
            id: s.int(0),
            mailbox: MailboxRef(id: s.int(2), account: s.text(1), name: s.text(3), role: MailboxRole(rawValue: s.text(4)) ?? .other),
            date: Date(timeIntervalSince1970: s.double(5)), subject: s.text(6), senderAddress: s.text(7),
            senderName: s.text(8), isRead: s.int(9) != 0, isFlagged: s.int(10) != 0, inInbox: s.int(11) != 0)
    }

    func metas(_ ids: [Int64]) throws -> [Int64: MessageMeta] {
        try read { db in
            var result: [Int64: MessageMeta] = [:]
            let statement = try db.prepare("SELECT \(Self.metaColumns) FROM messages m WHERE m.id=?")
            for id in ids {
                try statement.bind([.int(id)])
                if try statement.step() { result[id] = Self.meta(statement) }
            }
            return result
        }
    }

    /// Account addresses as stored, by message count.
    func accountList() throws -> [String] {
        try browse { db in
            var result: [String] = []
            try db.query("SELECT account FROM messages GROUP BY account ORDER BY count(*) DESC", []) { result.append($0.text(0)) }
            return result
        }
    }

    func accounts() throws -> Set<String> {
        try read { db in
            var result = Set<String>()
            try db.query("SELECT DISTINCT lower(account) FROM messages", []) { result.insert($0.text(0)) }
            return result
        }
    }

    func metaAndBody(_ ids: [Int64]) throws -> [Int64: (meta: MessageMeta, body: String)] {
        try read { db in
            var result: [Int64: (meta: MessageMeta, body: String)] = [:]
            let statement = try db.prepare("SELECT \(Self.metaColumns), m.body FROM messages m WHERE m.id=?")
            for id in ids {
                try statement.bind([.int(id)])
                if try statement.step() { result[id] = (Self.meta(statement), statement.text(12)) }
            }
            return result
        }
    }

    /// Newest messages in a browse box, with the start of their stored body.
    func recent(_ box: BrowseBox, limit: Int, offset: Int = 0, excludingFlagged: Bool = false, isRead: Bool? = nil,
                accounts: [String]? = nil, category: String? = nil) throws -> [(meta: MessageMeta, body: String)] {
        let (condition, args) = Self.browseCondition(box, excludingFlagged: excludingFlagged, isRead: isRead, accounts: accounts,
                                                     category: category)
        return try browse { db in
            var rows: [(meta: MessageMeta, body: String)] = []
            try db.query(
                "SELECT \(Self.metaColumns), substr(m.body, 1, 400) FROM messages m WHERE \(condition) ORDER BY m.date DESC LIMIT ? OFFSET ?",
                args + [.int(Int64(limit)), .int(Int64(offset))]) { rows.append((Self.meta($0), $0.text(12))) }
            return rows
        }
    }

    /// How many messages are in a browse box.
    func count(_ box: BrowseBox, accounts: [String]? = nil, category: String? = nil) throws -> Int {
        let (condition, args) = Self.browseCondition(box, excludingFlagged: false, isRead: nil, accounts: accounts, category: category)
        return try browse { db in
            var count = 0
            try db.query("SELECT count(*) FROM messages m WHERE \(condition)", args) { count = Int($0.int(0)) }
            return count
        }
    }

    private static func browseCondition(_ box: BrowseBox, excludingFlagged: Bool, isRead: Bool?, accounts: [String]?,
                                        category: String?) -> (sql: String, args: [SQLValue]) {
        var condition = boxCondition(box)
        if excludingFlagged { condition += " AND m.is_flagged = 0" }
        if let isRead { condition += isRead ? " AND m.is_read = 1" : " AND m.is_read = 0" }
        let only = whereClause(SearchFilter(accounts: accounts))
        condition += " AND " + only.sql
        var args = only.args
        if let category {
            condition += " AND m.id IN (SELECT id FROM categories WHERE category = ?)"
            args.append(.text(category))
        }
        return (condition, args)
    }

    /// All messages whose sender address equals `address` (case-insensitive), newest first.
    func metas(fromSender address: String, account: String?) throws -> [MessageMeta] {
        try read { db in
            var metas: [MessageMeta] = []
            var sql = "SELECT \(Self.metaColumns) FROM messages m WHERE m.sender_address = ? COLLATE NOCASE"
            var args: [SQLValue] = [.text(address)]
            if let account {
                sql += " AND m.account = ?"
                args.append(.text(account))
            }
            try db.query(sql + " ORDER BY m.date DESC", args) { metas.append(Self.meta($0)) }
            return metas
        }
    }

    func senderStats(account: String?, after: Date? = nil, limit: Int) throws -> [SenderStat] {
        try read { db in
            var stats: [SenderStat] = []
            // The bare sender_name column takes its value from the max(date) row: the latest display name.
            var sql = "SELECT sender_address, max(date), sender_name, account, count(*), sum(is_read = 0) FROM messages"
            var conditions: [String] = []
            var args: [SQLValue] = []
            if let account {
                conditions.append("account = ?")
                args.append(.text(account))
            }
            if let after {
                conditions.append("date >= ?")
                args.append(.double(after.timeIntervalSince1970))
            }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " GROUP BY account, lower(sender_address) ORDER BY count(*) DESC, max(date) DESC LIMIT ?"
            args.append(.int(Int64(limit)))
            try db.query(sql, args) {
                stats.append(SenderStat(
                    address: $0.text(0), name: $0.text(2), account: $0.text(3), count: Int($0.int(4)),
                    unread: Int($0.int(5)), latest: Date(timeIntervalSince1970: $0.double(1))))
            }
            return stats
        }
    }

    // MARK: - Search

    /// SQL conditions on alias `m` for `filter`. Sender matches a substring of the address or name, ignoring case.
    static func boxCondition(_ box: BrowseBox) -> String {
        switch box {
        case .inbox: "m.in_inbox = 1"
        case .archive: "m.in_inbox = 0"
        case .flagged: "m.is_flagged = 1"
        // Sent mail sits in All Mail like the rest; it is the mail the account sent itself.
        case .sent: "lower(m.sender_address) = lower(m.account)"
        case .unread: "m.in_inbox = 1 AND m.is_read = 0"
        }
    }

    static func whereClause(_ filter: SearchFilter) -> (sql: String, args: [SQLValue]) {
        var conditions: [String] = []
        var args: [SQLValue] = []
        if let account = filter.account {
            conditions.append("m.account = ?")
            args.append(.text(account))
        }
        if let accounts = filter.accounts {
            conditions.append("m.account IN (\(accounts.map { _ in "?" }.joined(separator: ",")))")
            args += accounts.map { .text($0) }
        }
        if let sender = filter.sender {
            conditions.append("(m.sender_address LIKE ? ESCAPE '\\' OR m.sender_name LIKE ? ESCAPE '\\')")
            let pattern = "%" + escapeLike(sender) + "%"
            args += [.text(pattern), .text(pattern)]
        }
        if let after = filter.after {
            conditions.append("m.date >= ?")
            args.append(.double(after.timeIntervalSince1970))
        }
        if let before = filter.before {
            conditions.append("m.date < ?")
            args.append(.double(before.timeIntervalSince1970))
        }
        return (conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), args)
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Lowercased sender address per message.
    func senderAddresses() throws -> [Int64: String] {
        try read { db in
            var out: [Int64: String] = [:]
            try db.query("SELECT id, lower(sender_address) FROM messages") { out[$0.int(0)] = $0.text(1) }
            return out
        }
    }

    /// Ids matching `filter`, or nil when the filter is empty.
    func ids(matching filter: SearchFilter) throws -> Set<Int64>? {
        let clause = Self.whereClause(filter)
        guard !clause.args.isEmpty else { return nil }
        return try read { db in
            var ids = Set<Int64>()
            try db.query("SELECT m.id FROM messages m WHERE \(clause.sql)", clause.args) { ids.insert($0.int(0)) }
            return ids
        }
    }

    /// Mail holding any of `groups` (each a word and then its translations, matched as substrings), best first. A
    /// translation counts only in the subject or sender: it names the kind of mail ("receipt"), and in long bodies it
    /// turns up by chance ("bill" in "billion"). Each group
    /// weighs ln(1 + N / mail holding it), so rare words decide and common ones ("for") barely count, and doubles in
    /// the subject or sender; the sum is scaled by the share of the query's weight the mail holds, so mail with only
    /// part of the query falls behind. Ties newest first. When every term has 3+ characters the trigram index narrows
    /// the scan (it has no positions, so a term's trigrams are ANDed and LIKE checks the term itself); shorter terms,
    /// such as most Chinese words, scan every message.
    func keywordSearch(_ groups: [[String]], filter: SearchFilter, limit: Int) throws -> [Int64] {
        let terms = groups.flatMap { $0 }
        guard !terms.isEmpty else { return [] }
        let inHeader = "(m.subject LIKE ? ESCAPE '\\' OR m.sender_name LIKE ? ESCAPE '\\' OR m.sender_address LIKE ? ESCAPE '\\')"
        let columns = terms.map { _ in inHeader + ", m.body LIKE ? ESCAPE '\\'" }.joined(separator: ", ")
        let termArgs = terms.flatMap { Array(repeating: SQLValue.text("%" + Self.escapeLike($0) + "%"), count: 4) }
        let clause = Self.whereClause(filter)
        let indexed = terms.allSatisfy { $0.unicodeScalars.count >= 3 }
        let from = indexed
            ? "messages_fts JOIN messages m ON m.id = messages_fts.rowid WHERE messages_fts MATCH ? AND "
            : "messages m WHERE "
        return try read { db in
            var total = 0
            try db.query("SELECT count(*) FROM messages m WHERE \(clause.sql)", clause.args) { total = Int($0.int(0)) }
            // Per row, per term: 2 in the subject or sender, 1 in the body only, 0 absent.
            var rows: [(id: Int64, date: Double, hits: [Double])] = []
            try db.query("SELECT m.id, m.date, \(columns) FROM \(from)\(clause.sql)",
                         termArgs + (indexed ? [.text(Self.trigramMatch(terms))] : []) + clause.args) { s in
                let termHits = terms.indices.map { s.int(Int32(2 + 2 * $0)) != 0 ? 2 : s.int(Int32(3 + 2 * $0)) != 0 ? 1 : 0 }
                var start = 0
                let hits = groups.map { group -> Double in
                    defer { start += group.count }
                    // The word itself anywhere; its translations only in the header, a little below the word.
                    let word = Double(termHits[start])
                    let translated = termHits[start + 1..<start + group.count].contains(2) ? 1.5 : 0
                    return max(word, translated)
                }
                if hits.contains(where: { $0 > 0 }) { rows.append((s.int(0), s.double(1), hits)) }
            }
            let weights = groups.indices.map { g -> Double in
                let holding = rows.filter { $0.hits[g] > 0 }.count
                return holding == 0 ? 0 : log(1 + Double(max(total, holding)) / Double(holding))
            }
            let totalWeight = weights.reduce(0, +)
            let scored = rows.map { row -> (Int64, Double, Double) in
                let sum = zip(row.hits, weights).reduce(0.0) { $0 + $1.0 * $1.1 }
                let held = zip(row.hits, weights).reduce(0.0) { $0 + ($1.0 > 0 ? $1.1 : 0) }
                return (row.id, row.date, totalWeight > 0 ? sum * held / totalWeight : 0)
            }
            return scored.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.1 > $1.1 }.prefix(limit).map(\.0)
        }
    }

    /// FTS5 query for mail holding all of a term's trigrams, for any of `terms` (code points, as the tokenizer counts).
    private static func trigramMatch(_ terms: [String]) -> String {
        terms.map { term -> String in
            let chars = Array(term.unicodeScalars)
            let trigrams = (0...chars.count - 3).map { i -> String in
                let trigram = String(String.UnicodeScalarView(chars[i..<i + 3]))
                return "\"" + trigram.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return "(" + trigrams.joined(separator: " AND ") + ")"
        }.joined(separator: " OR ")
    }

    /// Vectors with `seq` in (after, upTo], appended to `matrix` as Float32 rows. Returns the last seq read.
    func vectors(after seq: Int64, upTo: Int64, into matrix: inout [Float], ids: inout [Int64]) throws -> Int64 {
        try read { db in
            var last = seq
            try db.query("SELECT seq, id, vec FROM vectors WHERE seq > ? AND seq <= ? ORDER BY seq",
                         [.int(seq), .int(upTo)]) { row in
                let blob = row.blob(2)
                let halves = blob.bindMemory(to: Float16.self)
                matrix.append(contentsOf: halves.lazy.map { Float($0) })
                ids.append(row.int(1))
                last = row.int(0)
            }
            return last
        }
    }

    /// Mean embedding per sender (account + lowercased address) for senders with at least `minCount` vectors.
    func senderCentroids(minCount: Int, dimension: Int = 768) throws -> [(account: String, address: String, sum: [Float], count: Int)] {
        try read { db in
            var groups: [String: (account: String, address: String, sum: [Float], count: Int)] = [:]
            try db.query("SELECT m.account, lower(m.sender_address), v.vec FROM messages m JOIN vectors v ON v.id = m.id") { row in
                let key = row.text(0) + "|" + row.text(1)
                let halves = row.blob(2).bindMemory(to: Float16.self)
                var g = groups[key] ?? (row.text(0), row.text(1), [Float](repeating: 0, count: dimension), 0)
                for i in 0..<min(dimension, halves.count) { g.sum[i] += Float(halves[i]) }
                g.count += 1
                groups[key] = g
            }
            return groups.values.filter { $0.count >= minCount }
        }
    }

    func vectorState() throws -> (maxSeq: Int64, count: Int) {
        try read { db in
            var state: (maxSeq: Int64, count: Int) = (0, 0)
            try db.query("SELECT coalesce(max(seq), 0), count(*) FROM vectors") { state = ($0.int(0), Int($0.int(1))) }
            return state
        }
    }
}
