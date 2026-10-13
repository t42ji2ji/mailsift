import Foundation
import MailCore
import Observation

/// A proposed mail change, shown as a card until the user confirms or dismisses it.
struct AgentProposal: Codable {
    enum State: Equatable, Codable {
        case pending, running, cancelled
        case done(succeeded: Int, failed: Int)
        case failed(String)
    }

    var action: MailAction
    var ids: [Int64]
    var reason: String
    var state: State = .pending
    /// Per-message reasons, when the agent judged them one by one.
    var notes: [Int64: String]?
    /// Listed but left out of the action: the agent was unsure, or the user unticked them.
    var unchecked: Set<Int64>?

    var checked: [Int64] { ids.filter { unchecked?.contains($0) != true } }
}

/// A reply drafted by the agent, editable in the card and opened as a Mail compose window (never sent here).
struct AgentDraft: Codable {
    enum State: Equatable, Codable {
        case pending, opening, opened, cancelled
        case failed(String)
    }

    var id: Int64
    var body: String
    var replyAll: Bool
    var state: State = .pending
}

/// What the user did to a message from the transcript.
struct AgentMailState {
    var busy = false
    /// Set once the message left the list (trash, archive, junk).
    var removed: MailAction?
    var error: String?
}

struct AgentItem: Identifiable, Codable {
    enum Kind: Codable {
        case user(String)
        case assistant(String, streaming: Bool)
        case tool(String, running: Bool, failed: Bool)
        case proposal(AgentProposal)
        case draft(AgentDraft)
        case error(String)
    }

    let id: Int
    /// Assistant text: "messageID#index"; tool and proposal: the tool_use id.
    var key: String?
    var kind: Kind
}

/// The in-app assistant: runs the local Claude Code CLI headless with the mailsift MCP server, one process per turn
/// (`--resume` continues the conversation), and turns its stream into transcript items. Mail changes arrive as
/// `propose_action` calls and are performed here only after the user confirms.
@MainActor @Observable
final class AgentModel {
    private(set) var items: [AgentItem] = []
    private(set) var running = false
    /// Sender and subject per message id, from context, tool results and lookups; for `[[id]]` links.
    private(set) var refs: [Int64: MailRef] = [:]
    private(set) var backend: AgentBackend
    /// Resolved CLIs; a backend missing here was not found. Empty until `resolveBackends()` finishes.
    private(set) var launchers: [AgentBackend: Launcher] = [:]
    private(set) var resolved = false
    private(set) var mailStates: [Int64: AgentMailState] = [:]
    /// The drawer; in the model so other views can open it (reader's "請助理擬回覆").
    var isOpen = false

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let search: SearchModel
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var nextItem = 0
    @ObservationIgnored private var sawResult = false
    /// An error result without text; the cause is then on stderr.
    @ObservationIgnored private var silentError: String?
    /// Messages whose text arrived as deltas; their full `assistant` event only finalizes those items.
    @ObservationIgnored private var streamed = Set<String>()
    /// Confirmed or dismissed proposals since the last turn, reported in the next turn's context.
    @ObservationIgnored private var outcomes: [String] = []

    static let tools = ["search_mail", "read_mail", "read_thread", "list_recent", "list_senders", "index_status", "propose_action", "draft_reply"]
    static let workDir = MailLibrary.defaultDatabaseURL().deletingLastPathComponent().appendingPathComponent("agent")

    static let backendKey = "agentBackend"

    init(app: AppModel, search: SearchModel) {
        self.app = app
        self.search = search
        backend = UserDefaults.standard.string(forKey: Self.backendKey).flatMap(AgentBackend.init(rawValue:)) ?? .claude
        restore()
    }

    // MARK: - Saved conversation

    /// The current conversation, so it survives quitting the app.
    private struct Saved: Codable {
        var backend: AgentBackend
        var sessionID: String?
        var items: [AgentItem]
        var refs: [Int64: MailRef]
    }

    static let savedURL = workDir.appendingPathComponent("conversation.json")

    private func restore() {
        guard let data = try? Data(contentsOf: Self.savedURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.backend == backend else { return }
        sessionID = saved.sessionID
        refs = saved.refs
        // A quit mid-action leaves nothing running.
        items = saved.items.map { item in
            var item = item
            switch item.kind {
            case .proposal(var p) where p.state == .running: p.state = .pending; item.kind = .proposal(p)
            case .draft(var d) where d.state == .opening: d.state = .pending; item.kind = .draft(d)
            default: break
            }
            return item
        }
        nextItem = (items.map(\.id).max() ?? -1) + 1
        finishTurn()
    }

    private func save() {
        guard !items.isEmpty else {
            try? FileManager.default.removeItem(at: Self.savedURL)
            return
        }
        let saved = Saved(backend: backend, sessionID: sessionID, items: items, refs: refs)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: Self.workDir, withIntermediateDirectories: true)
        try? data.write(to: Self.savedURL, options: .atomic)
    }

    /// Switching starts a new conversation: sessions do not carry over between CLIs.
    func select(_ backend: AgentBackend) {
        guard backend != self.backend else { return }
        newConversation()
        self.backend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: Self.backendKey)
    }

    var isEmpty: Bool { items.isEmpty }

    /// Opens the drawer and asks for a reply draft to `id` (the open message is in the context).
    func requestDraft(_ id: Int64) {
        isOpen = true
        guard !running else { return }
        send("幫我擬 [[\(id)]] 的回覆")
    }

    func newConversation() {
        cancel()
        items = []
        sessionID = nil
        streamed = []
        outcomes = []
        save()
    }

    func cancel() {
        guard running else { return }
        run += 1  // drop whatever the old process still prints
        process?.terminate()
        process = nil
        finishTurn()
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        append(.user(text))
        running = true
        sawResult = false
        silentError = nil
        run += 1
        let run = run
        let system = systemPrompt()
        outcomes = []
        let backend = backend
        Task {
            await resolveBackends()
            guard run == self.run else { return }
            guard let launcher = launchers[backend] else {
                append(.error(Self.missing(backend)))
                finishTurn()
                return
            }
            start(launcher, backend: backend, prompt: text, system: system, run: run)
        }
    }

    // MARK: - Process

    struct Launcher {
        var executable: String
        var path: String
    }

    static func missing(_ backend: AgentBackend) -> String {
        switch backend {
        case .claude: "找不到 Claude Code。安裝並登入（在終端機執行 claude）後再試。"
        case .codex: "找不到 Codex CLI。安裝 Codex 或 ChatGPT app 並登入後再試。"
        }
    }

    /// Apps started from Finder get a minimal PATH; ask the login shell, then the usual install locations
    /// (`~/.local/bin` is often only added in .zshrc, which a non-interactive login shell skips).
    func resolveBackends() async {
        guard !resolved else { return }
        let found = await Task.detached { () -> [AgentBackend: Launcher] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "command -v claude; command -v codex; print -r -- $PATH"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            var lines: [String] = []
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = lines.last { $0.contains(":") } ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            let fallbacks: [AgentBackend: [String]] = [
                .claude: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
                .codex: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                         "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"],
            ]
            var result: [AgentBackend: Launcher] = [:]
            for backend in AgentBackend.allCases {
                let name = "/" + backend.rawValue
                let candidates = lines.filter { $0.hasSuffix(name) } + fallbacks[backend, default: []]
                guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { continue }
                result[backend] = Launcher(executable: exe, path: (exe as NSString).deletingLastPathComponent + ":" + path)
            }
            return result
        }.value
        launchers = found
        resolved = true
    }

    private func arguments(_ backend: AgentBackend, system: String) -> [String] {
        backend == .claude ? claudeArguments(system: system) : codexArguments(system: system)
    }

    private func claudeArguments(system: String) -> [String] {
        let mcp: [String: Any] = ["mcpServers": ["mailsift": ["command": CLIPath.url.path, "args": ["mcp"],
                                                              "env": ["MAILSIFT_AGENT": "1"]]]]
        let mcpJSON = String(decoding: try! JSONSerialization.data(withJSONObject: mcp), as: UTF8.self)
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--strict-mcp-config", "--mcp-config", mcpJSON,
                    "--tools", "",
                    "--allowedTools", Self.tools.map { "mcp__mailsift__" + $0 }.joined(separator: ","),
                    "--disallowedTools", "mcp__mailsift__perform_action,mcp__mailsift__preview_action",
                    "--setting-sources", "project", "--model", "sonnet",
                    "--append-system-prompt", system]
        if let sessionID { args += ["--resume", sessionID] }
        return args
    }

    /// Codex features that reach outside the mail tools (shell, browser, plugins…); the sandbox is read-only too.
    static let codexDisabled = ["shell_tool", "unified_exec", "apps", "plugins", "browser_use", "browser_use_external",
                                "in_app_browser", "computer_use", "image_generation", "multi_agent"]

    /// `codex exec [resume <id>] … -`. The user's config.toml is ignored; everything is passed with -c.
    private func codexArguments(system: String) -> [String] {
        func toml(_ s: String) -> String {
            // A JSON string literal is a valid TOML basic string once slashes are left unescaped.
            let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        var args = ["exec"]
        if sessionID != nil { args.append("resume") }
        args += ["--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                 "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\""]
        for feature in Self.codexDisabled { args += ["--disable", feature] }
        args += ["-c", "mcp_servers.mailsift.command=\(toml(CLIPath.url.path))",
                 "-c", "mcp_servers.mailsift.args=[\"mcp\"]",
                 "-c", "mcp_servers.mailsift.env.MAILSIFT_AGENT=\"1\"",
                 "-c", "mcp_servers.mailsift.default_tools_approval_mode=\"approve\"",
                 "-c", "developer_instructions=\(toml(system))"]
        if let sessionID { args.append(sessionID) }
        args.append("-")
        return args
    }

    private func start(_ launcher: Launcher, backend: AgentBackend, prompt: String, system: String, run: Int) {
        try? FileManager.default.createDirectory(at: Self.workDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launcher.executable)
        p.arguments = arguments(backend, system: system)
        p.currentDirectoryURL = Self.workDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = launcher.path
        p.environment = env
        // The prompt goes through stdin so text starting with "-" is never read as an option.
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        do {
            try p.run()
        } catch {
            append(.error("無法啟動 \(backend.title)：\(error.localizedDescription)"))
            finishTurn()
            return
        }
        process = p
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        // Blocking reads on their own threads; stderr is drained concurrently so a chatty child cannot stall.
        let errors = StderrBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errors.data = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        DispatchQueue.global().async {
            var buffer = AgentStream.LineBuffer()
            let out = stdout.fileHandleForReading
            while true {
                let data = out.availableData
                let lines = data.isEmpty ? buffer.finish() : buffer.append(data)
                let events = backend == .claude
                    ? lines.map(AgentStream.parse).filter { $0 != .ignored }
                    : lines.flatMap(AgentStream.parseCodex).map { $0.scoped("\(run)/") }
                if !events.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { events.forEach { self.handle($0, run: run) } } }
                }
                if data.isEmpty { break }
            }
            p.waitUntilExit()
            group.wait()
            let status = p.terminationStatus
            let stderrText = String(decoding: errors.data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.exited(backend, status: status, stderr: stderrText, run: run) }
            }
        }
    }

    private func exited(_ backend: AgentBackend, status: Int32, stderr: String, run: Int) {
        guard run == self.run else { return }
        process = nil
        if !sawResult || silentError != nil {
            let line = stderr.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            append(.error(line.map { String($0.prefix(300)) } ?? silentError ?? "\(backend.title) 已結束（代碼 \(status)）"))
        }
        finishTurn()
    }

    private func finishTurn() {
        running = false
        defer { save() }
        for i in items.indices {
            switch items[i].kind {
            case .assistant(let text, true): items[i].kind = .assistant(text, streaming: false)
            case .tool(let label, true, let failed): items[i].kind = .tool(label, running: false, failed: failed)
            default: break
            }
        }
    }

    // MARK: - Stream events

    func handle(_ event: AgentEvent, run: Int) {
        guard run == self.run else { return }
        switch event {
        case .initialized(let session, let mcp):
            sessionID = session
            if let mcp { append(.error("MailSift 工具無法連線（\(mcp)）")) }

        case .textDelta(let message, let index, let text):
            streamed.insert(message)
            let key = "\(message)#\(index)"
            if let i = items.lastIndex(where: { $0.key == key }), case .assistant(let old, true) = items[i].kind {
                items[i].kind = .assistant(old + text, streaming: true)
            } else {
                append(.assistant(text, streaming: true), key: key)
            }

        case .assistant(let message, let blocks):
            for block in blocks {
                switch block {
                case .text(let text):
                    // With deltas, each full block finalizes the oldest still-streaming block of that message.
                    if streamed.contains(message) {
                        if let i = items.firstIndex(where: {
                            guard $0.key?.hasPrefix(message + "#") == true, case .assistant(_, true) = $0.kind else { return false }
                            return true
                        }) {
                            items[i].kind = .assistant(text, streaming: false)
                        }
                    } else if !text.isEmpty {
                        append(.assistant(text, streaming: false), key: message)
                    }
                case .toolUse(let use):
                    guard !items.contains(where: { $0.key == use.id }) else { continue }
                    toolUse(use)
                }
            }

        case .toolResult(let id, let isError, let text):
            for ref in AgentStream.refs(inToolResult: text) { refs[ref.id] = ref }
            if let i = items.firstIndex(where: { $0.key == id }), case .tool(let label, _, _) = items[i].kind {
                items[i].kind = .tool(label, running: false, failed: isError)
            }

        case .result(let session, let isError, let subtype, let text, _):
            sawResult = true
            if let session { sessionID = session }
            if isError || subtype != "success" {
                if text.isEmpty { silentError = subtype } else { append(.error(String(text.prefix(300)))) }
            }

        case .failure(let text):
            append(.error(String(text.prefix(300))))

        case .ignored:
            break
        }
    }

    private func toolUse(_ use: AgentEvent.ToolUse) {
        let name = use.name.replacingOccurrences(of: "mcp__mailsift__", with: "")
        let input = AgentStream.object(use.input)
        if name == "draft_reply" {
            guard let id = (input["id"] as? NSNumber)?.int64Value, let body = input["body"] as? String else { return }
            append(.draft(AgentDraft(id: id, body: body, replyAll: input["reply_all"] as? Bool ?? false)), key: use.id)
            lookUp([id])
            return
        }
        if name == "propose_action" {
            guard let action = (input["action"] as? String).flatMap(MailAction.init(rawValue:)) else { return }
            var seen = Set<Int64>(), notes: [Int64: String] = [:], unchecked = Set<Int64>()
            var ids = (input["ids"] as? [NSNumber] ?? []).map(\.int64Value)
            for item in input["items"] as? [[String: Any]] ?? [] {
                guard let id = (item["id"] as? NSNumber)?.int64Value else { continue }
                ids.append(id)
                if let note = item["reason"] as? String, !note.isEmpty { notes[id] = note }
                if item["checked"] as? Bool == false { unchecked.insert(id) }
            }
            ids = ids.filter { seen.insert($0).inserted }
            guard !ids.isEmpty else { return }
            append(.proposal(AgentProposal(action: action, ids: ids, reason: input["reason"] as? String ?? "",
                                           notes: notes.isEmpty ? nil : notes, unchecked: unchecked.isEmpty ? nil : unchecked)),
                   key: use.id)
            lookUp(ids)
            return
        }
        append(.tool(Self.activity(name, input, refs: refs), running: true, failed: false), key: use.id)
    }

    static func activity(_ tool: String, _ input: [String: Any], refs: [Int64: MailRef]) -> String {
        switch tool {
        case "search_mail": return "搜尋「\(input["query"] as? String ?? "")」"
        case "list_recent":
            let range = [(input["after"] as? String).map { "\($0) 起" }, (input["before"] as? String).map { "\($0) 前" }]
                .compactMap { $0 }.joined(separator: "、")
            return range.isEmpty ? "列出最近的信" : "列出最近的信（\(range)）"
        case "read_mail", "read_thread":
            let id = (input["id"] as? NSNumber)?.int64Value ?? 0
            return (tool == "read_thread" ? "讀取對話串 " : "讀取 ")
                + (refs[id].map { $0.subject.isEmpty ? $0.sender : $0.subject } ?? "#\(id)")
        case "list_senders": return "統計寄件者"
        case "index_status": return "查看索引狀態"
        default: return tool
        }
    }

    /// Fills in sender/subject for ids the agent named but no tool result or context described.
    private func lookUp(_ ids: [Int64]) {
        let missing = Array(ids.filter { refs[$0] == nil }.prefix(200))
        guard !missing.isEmpty, let lib = app.library else { return }
        Task {
            let found = await Task.detached {
                missing.compactMap { id in
                    (try? lib.message(id: id)).map {
                        MailRef(id: id, sender: Fmt.sender($0.meta), subject: $0.meta.subject, isFlagged: $0.meta.isFlagged)
                    }
                }
            }.value
            for ref in found { refs[ref.id] = ref }
        }
    }

    // MARK: - Proposals

    func confirm(_ itemID: Int) {
        guard let i = items.firstIndex(where: { $0.id == itemID }), case .proposal(var proposal) = items[i].kind,
              proposal.state == .pending, !proposal.checked.isEmpty, let lib = app.library else { return }
        proposal.state = .running
        items[i].kind = .proposal(proposal)
        let ids = proposal.checked
        let left = proposal.ids.filter { !ids.contains($0) }
        let leftNote = left.isEmpty ? "" : " Left out by the user: \(left.map(String.init).joined(separator: ", "))."
        Task {
            do {
                let report = try await lib.perform(proposal.action, ids: ids)
                proposal.state = .done(succeeded: report.succeeded.count, failed: report.failed.count)
                outcomes.append("User confirmed \(proposal.action.rawValue) on \(ids.count) messages: "
                    + "\(report.succeeded.count) succeeded, \(report.failed.count) failed." + leftNote)
                applied(proposal.action, to: report.succeeded)
                refreshSearch(after: proposal.action, succeeded: report.succeeded)
            } catch {
                proposal.state = .failed(SearchModel.describe(error))
                outcomes.append("User confirmed \(proposal.action.rawValue) on \(ids.count) messages; it failed: \(error.localizedDescription)")
            }
            update(itemID) { $0 = proposal }
        }
    }

    func dismiss(_ itemID: Int) {
        update(itemID) { proposal in
            guard proposal.state == .pending else { return }
            proposal.state = .cancelled
            outcomes.append("User declined \(proposal.action.rawValue) on \(proposal.ids.count) messages.")
        }
    }

    /// Ticks or unticks one message of a pending proposal.
    func toggle(_ itemID: Int, _ id: Int64) {
        update(itemID) { proposal in
            guard proposal.state == .pending else { return }
            var unchecked = proposal.unchecked ?? []
            if unchecked.remove(id) == nil { unchecked.insert(id) }
            proposal.unchecked = unchecked
        }
    }

    func toggleAll(_ itemID: Int) {
        update(itemID) { proposal in
            guard proposal.state == .pending else { return }
            proposal.unchecked = proposal.checked.count == proposal.ids.count ? Set(proposal.ids) : []
        }
    }

    private func update(_ itemID: Int, _ change: (inout AgentProposal) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == itemID }), case .proposal(var proposal) = items[i].kind else { return }
        change(&proposal)
        items[i].kind = .proposal(proposal)
        save()
    }

    /// Mirrors a successful action on the transcript's mail rows.
    private func applied(_ action: MailAction, to ids: [Int64]) {
        for id in ids {
            switch action {
            case .trash, .archive, .junk: mailStates[id, default: .init()].removed = action
            case .restore: mailStates[id, default: .init()].removed = nil
            case .flag: refs[id]?.isFlagged = true
            case .unflag: refs[id]?.isFlagged = false
            case .markRead, .markUnread: break
            }
        }
    }

    // MARK: - Mail rows and drafts

    /// One action on one message from a transcript row.
    func act(_ action: MailAction, on id: Int64) {
        guard mailStates[id]?.busy != true, let lib = app.library else { return }
        mailStates[id, default: .init()].busy = true
        mailStates[id]?.error = nil
        Task {
            do {
                let report = try await lib.perform(action, ids: [id])
                if let why = report.failed[id] { mailStates[id]?.error = why }
                applied(action, to: report.succeeded)
                refreshSearch(after: action, succeeded: report.succeeded)
                if !report.succeeded.isEmpty { outcomes.append("User applied \(action.rawValue) to message \(id) from the transcript.") }
            } catch {
                mailStates[id]?.error = SearchModel.describe(error)
            }
            mailStates[id]?.busy = false
        }
    }

    func reply(to id: Int64) {
        guard let lib = app.library else { return }
        Task {
            do { try await lib.compose(.reply, id: id, body: nil) } catch {
                mailStates[id, default: .init()].error = SearchModel.describe(error)
            }
        }
    }

    func editDraft(_ itemID: Int, body: String) {
        updateDraft(itemID) { $0.body = body }
    }

    func openDraft(_ itemID: Int) {
        guard let i = items.firstIndex(where: { $0.id == itemID }), case .draft(let draft) = items[i].kind,
              draft.state == .pending || draft.state == .opened || draft.state.isFailure, let lib = app.library else { return }
        updateDraft(itemID) { $0.state = .opening }
        Task {
            do {
                try await lib.compose(draft.replyAll ? .replyAll : .reply, id: draft.id, body: draft.body)
                updateDraft(itemID) { $0.state = .opened }
                outcomes.append("User opened the reply draft for message \(draft.id) in Mail.")
            } catch {
                updateDraft(itemID) { $0.state = .failed(SearchModel.describe(error)) }
            }
        }
    }

    func cancelDraft(_ itemID: Int) {
        updateDraft(itemID) { $0.state = .cancelled }
    }

    private func updateDraft(_ itemID: Int, _ change: (inout AgentDraft) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == itemID }), case .draft(var draft) = items[i].kind else { return }
        change(&draft)
        items[i].kind = .draft(draft)
        save()
    }

    private func refreshSearch(after action: MailAction, succeeded: [Int64]) {
        app.refreshStatus()
        search.loadRecent()
        if !search.query.isEmpty { search.submit(search.query) }
        if [.trash, .archive, .junk].contains(action), let selected = search.selection, succeeded.contains(selected) {
            search.selection = nil
        }
    }

    // MARK: - Context

    /// Role, conventions, and what the user is looking at. Rebuilt every turn.
    private func systemPrompt(now: Date = .now) -> String {
        let tz = TimeZone.current
        let offset = tz.secondsFromGMT(for: now) / 60
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.dateFormat = "EEEE"
        let zone = String(format: "%@ (UTC%@%02d:%02d)", tz.identifier, offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
        var lines = [
            "You are the mail assistant inside MailSift, a macOS app that searches the user's Apple Mail.",
            "Answer in the user's language; default to Traditional Chinese (Taiwan). Be concise.",
            "Now: \(Fmt.date.string(from: now)) \(weekday.string(from: now)), \(zone).",
            "",
            "Tools:",
            "- list_recent for time-based questions and triage; search_mail for topics. Their rows carry signals (list = newsletter or notification, known = the user has written to this sender, replied, awaiting = waiting for the other side's answer) and list_recent filters on them; mailbox all includes mail the user sent. Combine tools freely; for cleanup, list_senders shows who sends the most and how much stays unread.",
            "- read_mail before summarizing or quoting a specific message; read_thread for the whole conversation.",
            "- To change mail (trash, archive, markRead, markUnread, flag, unflag, restore = move out of Trash back to the inbox, junk = mark as spam and move to Spam) call propose_action. When you judged messages one by one, pass items with a few-word reason each, and checked false for ones you are unsure about. The user unticks what to keep and confirms in the app. Never say mail was changed; say it is proposed.",
            "- To draft a reply, read_mail first, then call draft_reply with the id and the reply text (in the original message's language unless asked). The user edits it and opens it in Mail; nothing is sent.",
            "- Every time you mention a specific message, write its id as [[id]], e.g. [[12345]]. The app turns it into a link that opens the message, with mail actions, and the link already shows sender and subject, so don't repeat them. Use only ids from tool results or the context; never refer to a message by subject alone. Put each listed message on its own line.",
        ]
        if !outcomes.isEmpty { lines += ["", "Since your last reply:"] + outcomes.map { "- " + $0 } }

        lines += ["", "CONTEXT (what the user is looking at now)"]
        let visible = search.query.isEmpty ? search.recent : search.hits
        lines.append(search.query.isEmpty ? "List: newest mail" : "Search query: \(search.query)")
        for hit in visible.prefix(30) {
            let m = hit.meta
            refs[m.id] = MailRef(id: m.id, sender: Fmt.sender(m), subject: m.subject, isFlagged: m.isFlagged)
            lines.append("\(m.id) | \(Fmt.date.string(from: m.date)) | \(Fmt.sender(m)) | \(m.subject)\(m.isRead ? "" : " | unread")")
        }
        if visible.isEmpty { lines.append("(empty)") }
        if let m = search.message {
            refs[m.meta.id] = MailRef(id: m.meta.id, sender: Fmt.sender(m.meta), subject: m.meta.subject, isFlagged: m.meta.isFlagged)
            lines += ["", "Open message:", "id: \(m.meta.id)",
                      "from: \(m.meta.senderName) <\(m.meta.senderAddress)>",
                      "date: \(Fmt.date.string(from: m.meta.date))",
                      "subject: \(m.meta.subject)",
                      "body:", String(m.bodyText.prefix(1500))]
        } else {
            lines += ["", "Open message: none"]
        }
        return lines.joined(separator: "\n")
    }

    /// Text with `[[id]]` replaced by the sender/subject label, for plain views (the user's bubble).
    func plain(_ text: String) -> String {
        text.replacing(AgentStream.refPattern) { match in
            let id = Int64(match.1) ?? 0
            return refs[id].map { $0.subject.isEmpty ? $0.sender : $0.subject } ?? "#\(id)"
        }
    }

    private func append(_ kind: AgentItem.Kind, key: String? = nil) {
        items.append(AgentItem(id: nextItem, key: key, kind: kind))
        nextItem += 1
    }
}

private final class StderrBox: @unchecked Sendable {
    var data = Data()
}

extension AgentDraft.State {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}
