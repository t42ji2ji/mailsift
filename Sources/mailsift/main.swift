import Foundation
import MailCore

// mailsift — command-line access to the MailSift index, for people and for agents (Codex, Claude Code).
// Every command takes --json. Destructive actions are dry runs unless --yes is given.

let usage = """
    usage: mailsift <command> [options]

      status                         index progress
      index [--keyword-only]         sync new/removed mail, then embed (downloads the model on first run)
      search <query> [--limit N] [--account A] [--sender S] [--after YYYY-MM-DD] [--before YYYY-MM-DD]
      show <id>                      full message
      senders [--account A] [--limit N]
      trash   (--ids 1,2,3 | --sender ADDRESS [--account A]) [--yes]
      archive|mark-read|mark-unread|flag|unflag  --ids 1,2,3 [--yes]
      mcp                            run as an MCP server on stdio

      --json   machine-readable output
    """

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if ["json", "yes", "keyword-only"].contains(key) {
                    flags.insert(key)
                } else if i + 1 < argv.count {
                    options[key] = argv[i + 1]
                    i += 1
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    var json: Bool { flags.contains("json") }
    func int(_ key: String) -> Int? { options[key].flatMap(Int.init) }
    func date(_ key: String) -> Date? {
        guard let s = options[key] else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
    var ids: [Int64] {
        (options["ids"] ?? "").split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    print(String(data: try! e.encode(value), encoding: .utf8)!)
}

func fail(_ message: String, json: Bool) -> Never {
    if json {
        printJSON(["error": ["message": message]])
    } else {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
    exit(1)
}

let day: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

func pad(_ s: String, _ width: Int) -> String {
    let w = s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2E80 ? 2 : 1) }
    return w >= width ? s : s + String(repeating: " ", count: width - w)
}

func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

/// The model is only loaded when it is already on disk, except for `index`, which downloads it.
func modelInstalled() -> Bool {
    if ProcessInfo.processInfo.environment["EMBEDDINGGEMMA2_MODEL_DIR"] != nil { return true }
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MailSift/Models/embeddinggemma-2-coreml/EmbeddingGemma2Text.mlmodelc")
    return FileManager.default.fileExists(atPath: dir.path)
}

func openLibrary(json: Bool, loadModel: Bool) async -> MailLibrary {
    let source = AppleMailSource()
    do {
        try source.checkAccess()
    } catch {
        fail("\(error.localizedDescription) Grant Full Disk Access to this terminal (System Settings → Privacy & Security).", json: json)
    }
    var embedder: TextEmbedder?
    if loadModel {
        embedder = try? await CoreMLEmbedder.load()
    }
    do {
        return try MailLibrary(source: source, embedder: embedder)
    } catch {
        fail(error.localizedDescription, json: json)
    }
}

func describe(_ s: IndexStatus) -> String {
    var line = "\(s.phase.rawValue): \(s.keywordIndexed)/\(s.totalMessages) keyword, \(s.vectorIndexed) vectors"
    if let m = s.message { line += " (\(m))" }
    return line
}

let args = Args(Array(CommandLine.arguments.dropFirst()))
guard let command = args.positional.first else {
    print(usage)
    exit(0)
}
let json = args.json

switch command {
case "status":
    let lib = await openLibrary(json: json, loadModel: false)
    let s = lib.status()
    if json { printJSON(s) } else { print(describe(s)) }

case "index":
    let keywordOnly = args.flags.contains("keyword-only")
    let lib = await openLibrary(json: json, loadModel: false)
    let started = Date()
    let report: @Sendable (IndexStatus) -> Void = { s in
        if !json { FileHandle.standardError.write(Data("\r\(describe(s))   ".utf8)) }
    }
    do {
        try await lib.sync(progress: report)
        if !keywordOnly {
            if !json { FileHandle.standardError.write(Data("\nloading model (first run downloads ~570 MB and compiles for a few minutes)…\n".utf8)) }
            let embedder = try await CoreMLEmbedder.load { file, bytes in
                if !json, bytes == 0 { FileHandle.standardError.write(Data("  \(file)\n".utf8)) }
            }
            lib.setEmbedder(embedder)
            try await lib.embedPending(progress: report)
        }
    } catch {
        fail(error.localizedDescription, json: json)
    }
    let s = lib.status()
    if json { printJSON(s) } else { print("\n\(describe(s)) in \(Int(Date().timeIntervalSince(started)))s") }

case "search":
    let query = args.positional.dropFirst().joined(separator: " ")
    if query.isEmpty { fail("search needs a query", json: json) }
    let filter = SearchFilter(account: args.options["account"], sender: args.options["sender"],
                              after: args.date("after"), before: args.date("before"))
    let limit = args.int("limit") ?? 20
    do {
        // The running app answers with its model already in memory; otherwise this process loads its own.
        let hits: [SearchHit]
        if let served = SearchService.search(query, filter: filter, limit: limit) {
            hits = served
        } else {
            hits = try await openLibrary(json: json, loadModel: modelInstalled()).search(query, filter: filter, limit: limit)
        }
        if json {
            printJSON(["query": AnyEncodable(query), "hits": AnyEncodable(hits)])
        } else {
            for h in hits {
                print("\(pad(String(h.id), 7)) \(day.string(from: h.meta.date))  \(pad(clip(h.meta.senderName.isEmpty ? h.meta.senderAddress : h.meta.senderName, 22), 24))\(clip(h.meta.subject, 60))")
            }
            if hits.isEmpty { print("no results") }
        }
    } catch {
        fail(error.localizedDescription, json: json)
    }

case "show":
    guard let id = args.positional.dropFirst().first.flatMap(Int64.init) else { fail("show needs a message id", json: json) }
    let lib = await openLibrary(json: json, loadModel: false)
    do {
        var m = try lib.message(id: id)
        if json {
            m.html = nil
            printJSON(m)
        } else {
            print("ID:      \(m.meta.id)")
            print("From:    \(m.meta.senderName) <\(m.meta.senderAddress)>")
            print("To:      \(m.to.joined(separator: ", "))")
            if !m.cc.isEmpty { print("Cc:      \(m.cc.joined(separator: ", "))") }
            print("Date:    \(day.string(from: m.meta.date))")
            print("Account: \(m.meta.mailbox.account)  \(m.meta.mailbox.name)")
            print("Subject: \(m.meta.subject)\n")
            print(m.bodyText)
        }
    } catch {
        fail(error.localizedDescription, json: json)
    }

case "senders":
    let lib = await openLibrary(json: json, loadModel: false)
    let stats = lib.senders(account: args.options["account"], limit: args.int("limit") ?? 50)
    if json {
        printJSON(stats)
    } else {
        print("\(pad("COUNT", 7))\(pad("LATEST", 12))\(pad("ACCOUNT", 28))SENDER")
        for s in stats {
            let latest = String(day.string(from: s.latest).prefix(10))
            print("\(pad(String(s.count), 7))\(pad(latest, 12))\(pad(clip(s.account, 26), 28))\(s.name.isEmpty ? s.address : "\(s.name) <\(s.address)>")")
        }
    }

case "trash", "archive", "mark-read", "mark-unread", "flag", "unflag":
    let action: MailAction = ["trash": .trash, "archive": .archive, "mark-read": .markRead,
                              "mark-unread": .markUnread, "flag": .flag, "unflag": .unflag][command]!
    let lib = await openLibrary(json: json, loadModel: false)
    var ids = args.ids
    if let sender = args.options["sender"] {
        if action != .trash { fail("--sender is only supported for trash", json: json) }
        ids = lib.messages(fromSender: sender, account: args.options["account"]).map(\.id)
    }
    if ids.isEmpty { fail("no messages selected (use --ids or --sender)", json: json) }
    guard args.flags.contains("yes") else {
        if json {
            printJSON(["dry_run": AnyEncodable(true), "action": AnyEncodable(action.rawValue),
                       "count": AnyEncodable(ids.count), "ids": AnyEncodable(ids)])
        } else {
            print("dry run: would \(action.rawValue) \(ids.count) message(s). Re-run with --yes to do it.")
        }
        exit(0)
    }
    do {
        let r = try await lib.perform(action, ids: ids)
        if json {
            printJSON(r)
        } else {
            print("\(action.rawValue): \(r.succeeded.count) done, \(r.failed.count) failed")
            for (id, why) in r.failed.sorted(by: { $0.key < $1.key }).prefix(20) { print("  \(id): \(why)") }
        }
    } catch {
        fail(error.localizedDescription, json: json)
    }

case "mcp":
    // Searches go to the running app; this process loads its own model only when the app cannot answer.
    let lib = await openLibrary(json: false, loadModel: false)
    await MCPServer(library: lib) {
        Task {
            guard modelInstalled(), let embedder = try? await CoreMLEmbedder.load() else { return }
            lib.setEmbedder(embedder)
        }
    }.run()

default:
    print(usage)
    exit(1)
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
