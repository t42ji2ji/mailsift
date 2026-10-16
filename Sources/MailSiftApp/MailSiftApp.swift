import MailCore
import SwiftUI

@main
struct MailSiftApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("MailSift", id: "main") {
            RootView(app: app)
                .frame(minWidth: 600, minHeight: 560)
                .background(Theme.canvas)
                .task { app.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}

struct RootView: View {
    let app: AppModel

    var body: some View {
        switch app.readiness {
        case .checking:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsFullDiskAccess:
            AccessView(app: app, failure: nil)
        case .failed(let message):
            AccessView(app: app, failure: message)
        case .ready:
            MainView(app: app)
        }
    }
}

struct AccessView: View {
    let app: AppModel
    let failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Wordmark()
            if let failure {
                Text("無法讀取 Mail 資料").font(.system(size: 26, weight: .semibold))
                Text(failure).foregroundStyle(Theme.muted).textSelection(.enabled)
                Button("重新檢查") { app.start() }.buttonStyle(InkButtonStyle())
            } else {
                Text("需要完整磁碟取用權限").font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 12) {
                    Step(n: 1, text: "打開「系統設定 › 隱私權與安全性 › 完整磁碟取用權限」")
                    Step(n: 2, text: "開啟 MailSift")
                                    }
                HStack(spacing: 10) {
                    Button("打開系統設定") { app.openFullDiskAccessSettings() }
                        .buttonStyle(InkButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    Button("重新檢查") { app.start() }.buttonStyle(LineButtonStyle())
                }
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                app.recheckAccess()
            }
        }
    }

    private struct Step: View {
        let n: Int
        let text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(n)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Theme.ink.opacity(0.6)))
                Text(text).font(.system(size: 14))
            }
        }
    }
}

struct Wordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.ink).frame(width: 14, height: 14)
            if !compact { Text("MailSift").font(.system(size: 15, weight: .bold)).tracking(-0.2) }
        }
    }
}

struct MainView: View {
    enum Pane: Hashable {
        case box(BrowseBox), drafts, spam, trash, senders, status, settings

        static let mailboxes: [Pane] = [.box(.inbox), .box(.flagged), .box(.archive), .box(.sent), .drafts, .spam, .trash]

        var title: String {
            switch self {
            case .box(.inbox): "Inbox"
            case .box(.flagged): "旗標"
            case .box(.archive): "封存"
            case .box(.sent): "寄件備份"
            case .box(.unread): "未讀"
            case .drafts: "草稿"
            case .spam: "垃圾郵件"
            case .trash: "垃圾桶"
            case .senders: "寄件者"
            case .status: "索引"
            case .settings: "設定"
            }
        }

        var symbol: String {
            switch self {
            case .box(.inbox): "tray"
            case .box(.flagged): "flag"
            case .box(.archive): "archivebox"
            case .box(.sent): "paperplane"
            case .box(.unread): "envelope.badge"
            case .drafts: "doc.text"
            case .spam: "xmark.bin"
            case .trash: "trash"
            case .senders: "person.2"
            case .status: "circle.dashed"
            case .settings: "gearshape"
            }
        }

        var key: KeyEquivalent {
            switch self {
            case .box(.inbox), .box(.unread): "1"  // unread is opened from Inbox, not the rail
            case .box(.flagged): "2"
            case .box(.archive): "3"
            case .box(.sent): "4"
            case .drafts: "5"
            case .spam: "6"
            case .trash: "7"
            case .senders: "8"
            case .status: "9"
            case .settings: ","
            }
        }
    }

    let app: AppModel
    @State private var pane: Pane = .box(.inbox)
    /// The rail toggle: collapsed keeps only the icons.
    @State private var showRail = true
    /// Narrow window: the rail keeps only its icons.
    @State private var compactRail = false
    /// Inbox opened in the rail to pick accounts.
    @State private var showAccounts = false
    @State private var search: SearchModel
    @State private var senders: SendersModel
    @State private var trash: TrashModel
    @State private var spam: TrashModel
    @State private var drafts: TrashModel
    @State private var agent: AgentModel

    init(app: AppModel) {
        self.app = app
        _senders = State(initialValue: SendersModel(app: app))
        _trash = State(initialValue: TrashModel(app: app, role: .trash))
        _spam = State(initialValue: TrashModel(app: app, role: .spam))
        _drafts = State(initialValue: TrashModel(app: app, role: .drafts))
        let search = SearchModel(app: app)
        _search = State(initialValue: search)
        let agent = AgentModel(app: app, search: search)
        _agent = State(initialValue: agent)
        search.requestDraft = { agent.requestDraft($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Group {
                switch pane {
                case .box: SearchView(app: app, model: search)
                case .senders: SendersView(model: senders)
                case .trash: TrashView(model: trash).id(Pane.trash)
                case .spam: TrashView(model: spam).id(Pane.spam)
                case .drafts: TrashView(model: drafts).id(Pane.drafts)
                case .status: StatusView(app: app)
                case .settings: SettingsView(search: search)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: Bool.self) { $0.size.width < 900 } action: { compactRail = $0 }
        .onChange(of: pane) { if case .box(let b) = pane { search.box = b } }
        .onChange(of: search.box) { if case .box = pane { pane = .box(search.box) } }  // 顯示全部 and Esc switch boxes from the list
        .modifier(AgentDrawer(model: agent, hasMessage: search.message != nil) { id in
            // The current box, not Inbox: changing the box clears the selection.
            if case .box = pane {} else { pane = .box(search.box) }
            search.selection = id
        })
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                else { return event }
                return escape(in: event.window) ? nil : event
            }
        }
        .overlay(alignment: .topLeading) {
            // Sits in the title bar row, right of the traffic lights.
            IconButton(symbol: "sidebar.left", help: showRail ? "收起側邊欄" : "展開側邊欄") {
                withAnimation(.easeInOut(duration: 0.2)) { showRail.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .padding(.leading, 76)
            .padding(.top, -26)
        }
    }

    /// Esc peels one layer: the assistant, then the open message, then the box over Inbox.
    /// Left alone while a sheet is up or text is mid-composition, and while typing unless the assistant is open.
    private func escape(in window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        let editor = window.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return false }
        if agent.isOpen { agent.isOpen = false; return true }
        guard editor == nil, case .box = pane else { return false }
        if search.selection != nil {
            search.selection = nil
        } else if search.box != .inbox {
            search.box = .inbox
        } else {
            return false
        }
        return true
    }

    private var iconsOnly: Bool { compactRail || !showRail }

    private func railItem(_ p: Pane) -> some View {
        // The unread box is opened from Inbox, so Inbox stays selected over it.
        RailItem(title: p.title, symbol: p.symbol, selected: pane == p || p == .box(.inbox) && pane == .box(.unread),
                 compact: iconsOnly) { pane = p }
            .keyboardShortcut(p.key, modifiers: .command)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Wordmark(compact: iconsOnly)
                .padding(.leading, 10)
                .padding(.top, 46)
                .padding(.bottom, 22)
            railItem(.box(.inbox))
                .overlay(alignment: .trailing) {
                    if !iconsOnly, search.accounts.count + search.syncingAccounts.count > 1 {
                        Button { withAnimation(.easeInOut(duration: 0.15)) { showAccounts.toggle() } } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showAccounts ? 90 : 0))
                                .foregroundStyle(pane == .box(.inbox) || pane == .box(.unread) ? Theme.paper : Theme.muted)
                                .frame(width: 28, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(showAccounts ? "收起帳號" : "選擇帳號")
                    }
                }
            if showAccounts, !iconsOnly, search.accounts.count + search.syncingAccounts.count > 1 {
                ForEach(search.accounts, id: \.self) { account in
                    AccountItem(account: account, shown: !search.hiddenAccounts.contains(account),
                                isLast: search.accounts.allSatisfy { $0 == account || search.hiddenAccounts.contains($0) }) {
                        if search.hiddenAccounts.contains(account) {
                            search.hiddenAccounts.remove(account)
                        } else {
                            search.hiddenAccounts.insert(account)
                        }
                    }
                }
                ForEach(search.syncingAccounts, id: \.self) { SyncingAccountItem(account: $0) }
            }
            ForEach(Pane.mailboxes.dropFirst(), id: \.self, content: railItem)
            Spacer().frame(height: 14)
            railItem(.senders)
            Spacer()
            railItem(.status)
            railItem(.settings)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, iconsOnly ? 8 : 12)
        .frame(width: iconsOnly ? 56 : Theme.railWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Theme.paper)
    }
}

/// An account under Inbox in the rail; checked accounts are shown in every box and in search.
private struct AccountItem: View {
    let account: String
    let shown: Bool
    /// The only account still shown: it can't be unchecked.
    let isLast: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: shown ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(shown ? Theme.ink : Theme.muted)
                    .frame(width: 16)
                Text(account)
                    .font(.system(size: 12))
                    .foregroundStyle(shown ? Theme.ink : Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .padding(.trailing, 6)
            .frame(height: 26)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(shown && isLast)
        .help(account)
        .onHover { hovering = $0 }
    }
}

/// An account Mail is still downloading: listed so it's known to be coming, not yet selectable.
private struct SyncingAccountItem: View {
    let account: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini).frame(width: 16)
            Text(account).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text("同步中").font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .frame(height: 26)
        .help("\(account)：Apple Mail 還在下載這個帳號的信，下載好就會出現")
    }
}

private struct RailItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let compact: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
                if !compact {
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    Spacer()
                }
            }
            .foregroundStyle(selected ? Theme.paper : Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Theme.ink : (hovering ? Theme.hover : .clear), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(compact ? title : "")
        .onHover { hovering = $0 }
    }
}
