import AppKit
import MailCore
import SwiftUI

/// Floating assistant button (⌘J) and the right-hand drawer. When the window is wide enough the drawer pushes the
/// content aside, so a message opened from the transcript stays visible; otherwise it lies over the content and
/// closes when a message is opened.
struct AgentDrawer: ViewModifier {
    let model: AgentModel
    let hasMessage: Bool
    let openMessage: (Int64) -> Void
    @State private var width: CGFloat = 0

    static let panelWidth: CGFloat = 400
    /// Rail plus the narrowest message list.
    static let minContent: CGFloat = 560

    private var pushes: Bool { width - Self.panelWidth >= Self.minContent }

    func body(content: Content) -> some View {
        content
            .padding(.trailing, model.isOpen && pushes ? Self.panelWidth : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .bottomTrailing) {
                if !model.isOpen {
                    AgentButton(backend: model.backend) { toggle() }
                        .keyboardShortcut("j", modifiers: .command)
                        .padding(20)
                }
            }
            .overlay(alignment: .trailing) {
                if model.isOpen {
                    AgentPanel(model: model, hasMessage: hasMessage, openMessage: open) { toggle() }
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.isOpen)
    }

    private func toggle() { model.isOpen.toggle() }

    private func open(_ id: Int64) {
        openMessage(id)
        if !pushes { model.isOpen = false }
    }
}

private struct AgentButton: View {
    let backend: AgentBackend
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            BrandLogo(backend: backend, size: 20)
                .foregroundStyle(Theme.paper)
                .frame(width: 44, height: 44)
                .background(Theme.ink.opacity(hovering ? 0.85 : 1), in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("助理 · \(backend.title)（⌘J）")
    }
}

struct AgentPanel: View {
    let model: AgentModel
    let hasMessage: Bool
    let openMessage: (Int64) -> Void
    let close: () -> Void
    @State private var draft = ""
    @State private var composerHeight: CGFloat = 20
    /// Includes marked (composing) text, unlike `draft`.
    @State private var composerEmpty = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if model.isEmpty { suggestions } else { transcript }
            composer
        }
        .frame(width: AgentDrawer.panelWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.paper)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
        .shadow(color: .black.opacity(0.10), radius: 14, x: -3)
        .tint(Theme.ink)
        .environment(\.openURL, OpenURLAction { url in
            guard let id = AgentText.messageID(url) else { return .systemAction }
            openMessage(id)
            return .handled
        })
        .ignoresSafeArea(.container, edges: .top)
        .task { await model.resolveBackends() }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Spacer()
            BackendPicker(model: model).padding(.trailing, 6)
            IconButton(symbol: "square.and.pencil", help: "新對話") { model.newConversation() }
                .disabled(model.isEmpty)
            IconButton(symbol: "xmark", help: "關閉（⌘J）", action: close)
                .keyboardShortcut("j", modifiers: .command)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, 38)
        .padding(.bottom, 10)
    }

    private var suggestions: some View {
        let prompts = ["整理今天的待辦", "找出可能的垃圾郵件", "還沒回的信", "我寄出去還沒人回的", "很少讀的電子報"]
            + (hasMessage ? ["摘要目前這封信"] : [])
        return VStack(alignment: .leading, spacing: 8) {
            Spacer()
            ForEach(prompts, id: \.self) { prompt in
                Button(prompt) { model.send(prompt) }.buttonStyle(LineButtonStyle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                let logos = logoItems
                ForEach(model.items) { item in
                    AgentRow(item: item, model: model, logo: logos.contains(item.id), openMessage: openMessage)
                }
                if model.running, !showsProgress {
                    ProgressView().controlSize(.small).padding(.leading, 2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(maxHeight: .infinity)
    }

    /// The first assistant reply after each user message carries the backend's logo.
    private var logoItems: Set<Int> {
        var ids = Set<Int>()
        var awaiting = true
        for item in model.items {
            switch item.kind {
            case .user: awaiting = true
            case .assistant where awaiting:
                ids.insert(item.id)
                awaiting = false
            default: break
            }
        }
        return ids
    }

    /// The last row already shows activity (streaming text or a running tool).
    private var showsProgress: Bool {
        switch model.items.last?.kind {
        case .assistant(_, true), .tool(_, true, _): true
        default: false
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            AgentComposer(text: $draft, height: $composerHeight, isEmpty: $composerEmpty) { send() }
                .frame(height: min(max(composerHeight, 20), 140))
                .overlay(alignment: .topLeading) {
                    if composerEmpty {
                        Text("問問你的信件").font(.system(size: 13)).foregroundStyle(Theme.faint).allowsHitTesting(false)
                    }
                }
            if model.running {
                IconButton(symbol: "stop.fill", help: "停止") { model.cancel() }
            } else {
                IconButton(symbol: "arrow.up", help: "送出（Enter）") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10))
        .hairlineBorder(10)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
    }

    private func send() {
        guard !model.running, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.send(draft)
        draft = ""
    }
}

private struct AgentRow: View {
    let item: AgentItem
    let model: AgentModel
    let logo: Bool
    let openMessage: (Int64) -> Void

    var body: some View {
        if case .user(let text) = item.kind {
            HStack {
                Spacer(minLength: 48)
                Text(model.plain(text))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.paper)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            // Agent rows share a gutter so the logo lines up with the text it introduces.
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if logo { BrandLogo(backend: model.backend, size: 13).foregroundStyle(Theme.muted) }
                }
                .frame(width: 14, alignment: .leading)
                .padding(.top, 2)
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .user:
            EmptyView()
        case .assistant(let text, _):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(AgentStream.segments(text).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        Text(AgentText.attributed(text, refs: model.refs))
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .mail(let id, let line):
                        MailRow(id: id, model: model, openMessage: openMessage) {
                            Text(AgentText.attributed(line, refs: model.refs)).font(.system(size: 13)).lineSpacing(3)
                        }
                    }
                }
            }
        case .tool(let label, let running, let failed):
            HStack(spacing: 6) {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: failed ? "exclamationmark.circle" : "checkmark").font(.system(size: 9, weight: .semibold))
                }
                Text(running ? label + "…" : label).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
        case .proposal(let proposal):
            ProposalCard(proposal: proposal, itemID: item.id, model: model, openMessage: openMessage)
        case .draft(let draft):
            DraftCard(draft: draft, itemID: item.id, model: model, openMessage: openMessage)
        case .error(let text):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                Text(text).textSelection(.enabled)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
        }
    }
}

private struct ProposalCard: View {
    let proposal: AgentProposal
    let itemID: Int
    let model: AgentModel
    let openMessage: (Int64) -> Void
    @State private var expanded: Bool

    static let shown = 100

    init(proposal: AgentProposal, itemID: Int, model: AgentModel, openMessage: @escaping (Int64) -> Void) {
        self.proposal = proposal
        self.itemID = itemID
        self.model = model
        self.openMessage = openMessage
        // Judged one by one, or something left unticked: the list is the point, so it starts open.
        _expanded = State(initialValue: proposal.notes != nil || proposal.unchecked != nil)
    }

    private var pending: Bool { proposal.state == .pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AgentText.label(proposal.action)).font(.system(size: 13, weight: .semibold))
                Text(pending && proposal.checked.count != proposal.ids.count
                     ? "\(Fmt.count(proposal.checked.count)) / \(Fmt.count(proposal.ids.count)) 封"
                     : "\(Fmt.count(proposal.ids.count)) 封")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
                Spacer()
                if pending, expanded {
                    Button(proposal.checked.count == proposal.ids.count ? "全不選" : "全選") { model.toggleAll(itemID) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
            }
            if !proposal.reason.isEmpty {
                Text(proposal.reason).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(expanded ? "收合" : "顯示信件")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { list }
            footer
        }
        .padding(12)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.radius))
        .hairlineBorder()
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(proposal.ids.prefix(Self.shown), id: \.self) { id in
                let on = proposal.unchecked?.contains(id) != true
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if pending {
                        Button { model.toggle(itemID, id) } label: {
                            Image(systemName: on ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(on ? Theme.ink : Theme.faint)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    MailRow(id: id, model: model, openMessage: openMessage) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.refs[id].map { "\($0.sender)　\($0.subject.isEmpty ? "（無主旨）" : $0.subject)" } ?? "#\(id)")
                                .font(.system(size: 12))
                                .lineLimit(1)
                            if let note = proposal.notes?[id] {
                                Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                            }
                        }
                        .opacity(on || !pending ? 1 : 0.5)
                    }
                }
            }
            if proposal.ids.count > Self.shown {
                Text("另外 \(Fmt.count(proposal.ids.count - Self.shown)) 封").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch proposal.state {
        case .pending:
            HStack(spacing: 8) {
                Button(proposal.checked.count == proposal.ids.count ? "確認" : "確認 \(Fmt.count(proposal.checked.count)) 封") {
                    model.confirm(itemID)
                }
                .buttonStyle(InkButtonStyle())
                .disabled(proposal.checked.isEmpty)
                Button("取消") { model.dismiss(itemID) }.buttonStyle(LineButtonStyle())
            }
        case .running:
            ProgressView().controlSize(.small)
        case .done(let succeeded, let failed):
            Text("完成 \(Fmt.count(succeeded)) 封 · 失敗 \(Fmt.count(failed)) 封")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
        case .cancelled:
            Text("已取消").font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .failed(let message):
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
        }
    }
}

/// A message named in the transcript: click opens it; on hover, 封存 / 垃圾桶 / 旗標 / 回覆 act on it right here.
private struct MailRow<Label: View>: View {
    let id: Int64
    let model: AgentModel
    let openMessage: (Int64) -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false
    @State private var confirmTrash = false

    var body: some View {
        let state = model.mailStates[id]
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                label
                    .opacity(state?.removed == nil ? 1 : 0.45)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let removed = state?.removed {
                    Text(Self.done(removed)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            if let error = state?.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if state?.busy == true {
                ProgressView().controlSize(.mini).padding(4)
            } else if hovering, state?.removed == nil {
                actions.background(Theme.paper, in: RoundedRectangle(cornerRadius: 6)).hairlineBorder(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openMessage(id) }
        .onHover { hovering = $0 }
        .help("開啟這封信")
        .confirmationDialog("將這封郵件移到垃圾桶？", isPresented: $confirmTrash) {
            Button("移到垃圾桶", role: .destructive) { model.act(.trash, on: id) }
        }
        .padding(.horizontal, -6)
    }

    private var actions: some View {
        let flagged = model.refs[id]?.isFlagged ?? false
        return HStack(spacing: 0) {
            SmallAction(symbol: "archivebox", help: "封存") { model.act(.archive, on: id) }
            SmallAction(symbol: "trash", help: "移到垃圾桶") { confirmTrash = true }
            SmallAction(symbol: flagged ? "flag.fill" : "flag", help: flagged ? "移除旗標" : "加旗標") {
                model.act(flagged ? .unflag : .flag, on: id)
            }
            SmallAction(symbol: "arrowshape.turn.up.left", help: "回覆") { model.reply(to: id) }
        }
    }

    static func done(_ action: MailAction) -> String {
        switch action {
        case .archive: "已封存"
        case .junk: "已標為垃圾郵件"
        default: "已移到垃圾桶"
        }
    }
}

private struct SmallAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink)
                .frame(width: 24, height: 22)
                .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A reply the agent drafted: editable here, then opened as a Mail compose window. Nothing is sent from the app.
private struct DraftCard: View {
    let draft: AgentDraft
    let itemID: Int
    let model: AgentModel
    let openMessage: (Int64) -> Void
    @State private var text: String

    init(draft: AgentDraft, itemID: Int, model: AgentModel, openMessage: @escaping (Int64) -> Void) {
        self.draft = draft
        self.itemID = itemID
        self.model = model
        self.openMessage = openMessage
        _text = State(initialValue: draft.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.replyAll ? "全部回覆草稿" : "回覆草稿").font(.system(size: 13, weight: .semibold))
            MailRow(id: draft.id, model: model, openMessage: openMessage) {
                Text(model.refs[draft.id].map { "給 \($0.sender)　Re: \($0.subject)" } ?? "#\(draft.id)")
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90, maxHeight: 240)
                .padding(6)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 6))
                .hairlineBorder(6)
                .disabled(draft.state == .cancelled || draft.state == .opening)
                .onChange(of: text) { model.editDraft(itemID, body: text) }
            footer
        }
        .padding(12)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.radius))
        .hairlineBorder()
    }

    @ViewBuilder private var footer: some View {
        switch draft.state {
        case .pending, .opened, .failed:
            VStack(alignment: .leading, spacing: 6) {
                if case .failed(let message) = draft.state {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Button(draft.state == .opened ? "再次在 Mail 開啟" : "在 Mail 開啟") { model.openDraft(itemID) }
                        .buttonStyle(InkButtonStyle())
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if draft.state != .opened {
                        Button("取消") { model.cancelDraft(itemID) }.buttonStyle(LineButtonStyle())
                    }
                }
            }
        case .opening:
            ProgressView().controlSize(.small)
        case .cancelled:
            Text("已取消").font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

/// Two-way switch between the CLIs. A CLI that was not found stays visible but inert, with the reason on hover.
private struct BackendPicker: View {
    let model: AgentModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgentBackend.allCases, id: \.self) { backend in
                let selected = model.backend == backend
                let available = !model.resolved || model.launchers[backend] != nil
                Button {
                    if available { model.select(backend) }
                } label: {
                    HStack(spacing: 5) {
                        BrandLogo(backend: backend, size: 12)
                        Text(backend.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(selected ? Theme.paper : Theme.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(selected ? Theme.ink : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .opacity(available ? 1 : 0.35)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(available ? backend.title : AgentModel.missing(backend))
            }
        }
        .padding(2)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Simple Icons marks (CC0) from Resources/Brand, drawn as templates so they follow ink and paper.
/// Unbundled builds have no resources and fall back to an SF Symbol.
struct BrandLogo: View {
    let backend: AgentBackend
    var size: CGFloat = 14

    private static let images: [AgentBackend: NSImage] = {
        var images: [AgentBackend: NSImage] = [:]
        for backend in AgentBackend.allCases {
            let name = backend == .claude ? "Claude" : "OpenAI"
            guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
                  let image = NSImage(contentsOf: url) else { continue }
            image.isTemplate = true
            images[backend] = image
        }
        return images
    }()

    var body: some View {
        if let image = Self.images[backend] {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: backend == .claude ? "asterisk" : "circle.hexagongrid")
                .font(.system(size: size * 0.8, weight: .medium))
                .frame(width: size, height: size)
        }
    }
}

/// Assistant text: inline Markdown, with `[[id]]` turned into links that open the message.
enum AgentText {
    static let scheme = "mailsift"

    static func label(_ action: MailAction) -> String {
        switch action {
        case .trash: "移到垃圾桶"
        case .archive: "封存"
        case .markRead: "標為已讀"
        case .markUnread: "標為未讀"
        case .flag: "加旗標"
        case .unflag: "移除旗標"
        case .restore: "還原"
        case .junk: "標為垃圾郵件"
        }
    }

    static func messageID(_ url: URL) -> Int64? {
        url.scheme == scheme ? Int64(url.lastPathComponent) : nil
    }

    static func attributed(_ text: String, refs: [Int64: MailRef]) -> AttributedString {
        // Block syntax is not parsed in inline mode: headings become bold lines, list markers bullets.
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? line : "**\(title)**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return String(line.prefix(line.count - trimmed.count)) + "• " + trimmed.dropFirst(2)
            }
            return line
        }
        let source = lines.joined(separator: "\n").replacing(AgentStream.refPattern) { match in
            let id = Int64(match.1) ?? 0
            return "[\(escape(chip(id, refs)))](\(scheme)://message/\(id))"
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var result = try? AttributedString(markdown: source, options: options) else { return AttributedString(text) }
        for run in result.runs {
            guard let url = run.link, url.scheme == scheme else { continue }
            result[run.range].backgroundColor = Theme.selected
            result[run.range].font = .system(size: 12, weight: .medium)
        }
        return result
    }

    private static func chip(_ id: Int64, _ refs: [Int64: MailRef]) -> String {
        guard let ref = refs[id] else { return "#\(id)" }
        let subject = ref.subject.isEmpty ? "（無主旨）" : ref.subject
        let full = ref.sender.isEmpty ? subject : "\(ref.sender) · \(subject)"
        return full.count > 48 ? String(full.prefix(47)) + "…" : full
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\[]*_`<>".contains(c) { out.append("\\") }
            out.append(c)
        }
        return " \(out) "
    }
}

/// Multi-line input. Enter sends, Shift+Enter inserts a newline. An Enter that belongs to an input method
/// (Zhuyin candidate selection, or the keystroke that commits the composition) never sends.
struct AgentComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isEmpty: Bool
    var onSend: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 13)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView, !view.hasMarkedText(), view.string != text else { return }
        view.string = text
        let empty = text.isEmpty
        DispatchQueue.main.async { isEmpty = empty }
        context.coordinator.measure(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// An Enter this soon after a composition ended is the one that committed it.
        static let commitGrace: TimeInterval = 0.1

        var parent: AgentComposer

        init(parent: AgentComposer) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? ComposerTextView else { return }
            if !view.hasMarkedText() { parent.text = view.string }
            if parent.isEmpty != view.string.isEmpty { parent.isEmpty = view.string.isEmpty }
            measure(view)
        }

        func measure(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let h = ceil(layout.usedRect(for: container).height)
            if h != parent.height { DispatchQueue.main.async { self.parent.height = h } }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let view = textView as? ComposerTextView else { return false }
            if view.hasMarkedText() || view.composingAtKeyDown
                || Date().timeIntervalSince(view.compositionEnded) < Self.commitGrace {
                return true
            }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                view.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.text = view.string
            parent.onSend()
            return true
        }
    }
}

final class ComposerTextView: NSTextView {
    /// Whether an input method was composing when the current key went down.
    private(set) var composingAtKeyDown = false
    private(set) var compositionEnded = Date.distantPast

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        composingAtKeyDown = hasMarkedText()
        super.keyDown(with: event)
        composingAtKeyDown = false
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let composing = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        if composing { compositionEnded = Date() }
    }

    override func unmarkText() {
        let composing = hasMarkedText()
        super.unmarkText()
        if composing { compositionEnded = Date() }
    }
}
