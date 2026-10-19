import AppKit
import MailCore
import SwiftUI

struct SettingsView: View {
    static let loadRemoteKey = "loadRemoteContent"
    let app: AppModel
    let search: SearchModel
    @AppStorage(loadRemoteKey) private var loadRemote = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("設定").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("郵件內容")
                    Toggle(isOn: $loadRemote) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自動載入遠端內容").font(.system(size: 13, weight: .medium))
                            Text("郵件裡的圖片、樣式和字型直接從寄件方的伺服器載入，對方會看到你的 IP 和讀信時間。關閉後，每封信可以用工具列的圖片按鈕個別載入。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                }
                CategorySettings(search: search)
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("帳號")
                    Text("MailSift 讀的是 Apple Mail 裡的帳號。在系統設定的「網際網路帳號」加入帳號並開啟「郵件」，下一次同步就會出現。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !search.accounts.isEmpty || !search.syncingAccounts.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(search.accounts, id: \.self) { AccountRow(account: $0, syncing: false) }
                            ForEach(search.syncingAccounts, id: \.self) { AccountRow(account: $0, syncing: true) }
                        }
                    }
                    Button("新增郵件帳號…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                    }
                    .buttonStyle(LineButtonStyle())
                }
                IndexSettings(app: app)
                AgentSetupSettings()
            }
            .overlayScroller()
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An account set up in Apple Mail; one still downloading says so.
private struct AccountRow: View {
    let account: String
    let syncing: Bool

    var body: some View {
        HStack(spacing: 10) {
            if syncing {
                ProgressView().controlSize(.mini).frame(width: 16)
            } else {
                Image(systemName: "envelope").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 16)
            }
            Text(account).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if syncing { Text("同步中").font(.system(size: 11)).foregroundStyle(Theme.faint) }
        }
        .frame(height: 30)
        .help(syncing ? "\(account)：Apple Mail 還在下載這個帳號的信，下載好就會出現" : account)
    }
}

/// Order (drag), visibility and custom categories for the chips over the list.
private struct CategorySettings: View {
    let search: SearchModel
    @State private var items: [MailCategory] = []
    /// The custom category in the form: an existing id, or nil for a new one.
    @State private var editing: String?
    @State private var formOpen = false
    @State private var name = ""
    @State private var detail = ""
    private static let rowHeight: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("分類")
            Text("拖曳調整順序。隱藏只是不顯示標籤；新增或修改描述後，所有信會重新分類一次。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(items) { row($0) }
                    .onMove { from, to in
                        items.move(fromOffsets: from, toOffset: to)
                        search.saveCategories(items)
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(items.count) * Self.rowHeight)
            .hairlineBorder()
            if formOpen { form } else {
                Button("新增分類") { open(nil) }.buttonStyle(LineButtonStyle())
            }
        }
        .onAppear { items = search.library?.categories() ?? search.categories }
    }

    private func row(_ c: MailCategory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text(c.name).font(.system(size: 13, weight: .medium)).foregroundStyle(c.hidden ? Theme.faint : Theme.ink)
            if !c.isBuiltIn {
                Text(c.description).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !c.isBuiltIn {
                IconButton(symbol: "pencil", help: "編輯") { open(c) }
                IconButton(symbol: "trash", help: "刪除") { update { $0.removeAll { $0.id == c.id } } }
            }
            IconButton(symbol: c.hidden ? "eye.slash" : "eye", help: c.hidden ? "顯示標籤" : "隱藏標籤") {
                update { list in
                    if let i = list.firstIndex(where: { $0.id == c.id }) { list[i].hidden.toggle() }
                }
            }
        }
        .frame(height: Self.rowHeight)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("名稱") {
                TextField("", text: $name, prompt: Text("例如：學校"))
            }
            field("描述") {
                TextField("", text: $detail, prompt: Text("例如：學校課程、作業繳交、期中考、教授與助教公告、選課 course, assignment, exam"), axis: .vertical)
                    .lineLimit(3...6)
            }
            Text("寫這類信裡真的會出現的字：常見主旨、寄件單位、服務名稱，中英文都放。具體的詞比多更重要，別寫到其他分類也會出現的字，例如「通知」「更新」。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(editing == nil ? "新增" : "儲存") { save() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || detail.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("取消") { formOpen = false }.buttonStyle(LineButtonStyle())
            }
        }
        .padding(16)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func field(_ label: String, @ViewBuilder _ input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            input()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.radius))
                .hairlineBorder()
        }
    }

    private func open(_ c: MailCategory?) {
        editing = c?.id
        name = c?.name ?? ""
        detail = c?.description ?? ""
        formOpen = true
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        update { list in
            if let id = editing, let i = list.firstIndex(where: { $0.id == id }) {
                list[i].name = name
                list[i].description = detail
            } else {
                list.append(MailCategory(name: name, description: detail))
            }
        }
        formOpen = false
    }

    private func update(_ change: (inout [MailCategory]) -> Void) {
        change(&items)
        search.saveCategories(items)
    }
}

/// How much of the mail has a semantic index, and a manual resync.
private struct IndexSettings: View {
    let app: AppModel

    var body: some View {
        let s = app.status
        let share = s.totalMessages > 0 ? Double(s.vectorIndexed) / Double(s.totalMessages) : 0
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("索引")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int((share * 100).rounded(.down)))%")
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .tracking(-0.5)
                Text(detail(s)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                Button("重新同步") { app.resync() }.buttonStyle(LineButtonStyle())
            }
            ThinProgress(value: share).frame(height: 3)
        }
    }

    private func detail(_ s: IndexStatus) -> String {
        if case .loading = app.model { return "搜尋模型" + Fmt.model(app.model) }
        if case .failed = app.model { return Fmt.model(app.model) }
        return "\(Fmt.phase(s.phase)) · \(Fmt.count(s.vectorIndexed)) / \(Fmt.count(s.totalMessages)) 封"
    }
}

/// One copy per agent: English instructions to paste into Claude Code or Codex, which add
/// MailSift as an MCP server themselves and learn what its tools are for.
private struct AgentSetupSettings: View {
    @State private var copied: AgentBackend?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("連接 Claude Code · Codex")
            Text("複製後貼進 Claude Code 或 Codex 的對話，它會自己把 MailSift 接成 MCP server，之後在任何資料夾都能用語意搜尋、讀你的信。執行它的終端機需要「完全取用磁碟」權限；MailSift 開著時搜尋最快。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(AgentBackend.allCases, id: \.self) { backend in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgentSetup.prompt(for: backend), forType: .string)
                        copied = backend
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            if copied == backend { copied = nil }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if copied == backend { Image(systemName: "checkmark") } else { BrandLogo(backend: backend, size: 13) }
                            Text(copied == backend ? "已複製" : "複製給 \(backend.title)")
                        }
                    }
                    .buttonStyle(LineButtonStyle())
                }
            }
        }
    }
}

enum AgentSetup {
    static func addCommand(for backend: AgentBackend) -> String {
        switch backend {
        case .claude: "claude mcp add --scope user mailsift -- \(CLIPath.quoted) mcp"
        case .codex: "codex mcp add mailsift -- \(CLIPath.quoted) mcp"
        }
    }

    static func prompt(for backend: AgentBackend) -> String {
        """
        I use MailSift, a Mac app that indexes all of my Apple Mail locally: every message is embedded on this Mac \
        (EmbeddingGemma 2) for semantic search, alongside a keyword index and topic categories. Please connect it as an \
        MCP server by running this in the shell:

        \(addCommand(for: backend))

        Then, whenever I ask about my email, use its tools instead of guessing:
        - search_mail: search by meaning. Describe what the message is about in any language; it doesn't need the exact words.
        - list_recent: recent mail by time, with filters for newsletters, known senders, replied and awaiting a reply.
        - read_mail / read_thread: read one message, or the whole conversation it belongs to.
        - list_senders: who sends the most and how much of it stays unread, for cleanup.
        - index_status: how much of the mailbox is indexed so far.
        - preview_action, then perform_action: archive, trash, flag or mark read. Always show me the preview and wait \
        for my confirmation before perform_action.

        Without MCP, the same index answers from the shell: \(CLIPath.quoted) search "<what you're looking for>" --json
        The terminal running you needs Full Disk Access to read Mail's data. Searches are fastest while MailSift is open.
        """
    }
}

enum CLIPath {
    /// The CLI shipped in Contents/Helpers; when running unbundled, the build directory's.
    static let url: URL = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mailsift")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("mailsift")
    }()

    static var quoted: String { "\"\(url.path)\"" }
}
