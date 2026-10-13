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
    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.ink).frame(width: 14, height: 14)
            Text("MailSift").font(.system(size: 15, weight: .bold)).tracking(-0.2)
        }
    }
}

struct MainView: View {
    enum Pane: Hashable {
        case box(BrowseBox), spam, trash, senders, status, settings

        static let mailboxes: [Pane] = [.box(.inbox), .box(.flagged), .box(.archive), .spam, .trash]

        var title: String {
            switch self {
            case .box(.inbox): "Inbox"
            case .box(.flagged): "旗標"
            case .box(.archive): "封存"
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
            case .spam: "xmark.bin"
            case .trash: "trash"
            case .senders: "person.2"
            case .status: "circle.dashed"
            case .settings: "gearshape"
            }
        }

        var key: KeyEquivalent {
            switch self {
            case .box(.inbox): "1"
            case .box(.flagged): "2"
            case .box(.archive): "3"
            case .spam: "4"
            case .trash: "5"
            case .senders: "6"
            case .status: "7"
            case .settings: ","
            }
        }
    }

    let app: AppModel
    @State private var pane: Pane = .box(.inbox)
    @State private var showRail = true
    @State private var search: SearchModel
    @State private var senders: SendersModel
    @State private var trash: TrashModel
    @State private var spam: TrashModel
    @State private var agent: AgentModel

    init(app: AppModel) {
        self.app = app
        _senders = State(initialValue: SendersModel(app: app))
        _trash = State(initialValue: TrashModel(app: app, role: .trash))
        _spam = State(initialValue: TrashModel(app: app, role: .spam))
        let search = SearchModel(app: app)
        _search = State(initialValue: search)
        let agent = AgentModel(app: app, search: search)
        _agent = State(initialValue: agent)
        search.requestDraft = { agent.requestDraft($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showRail {
                rail.transition(.move(edge: .leading))
                Rectangle().fill(Theme.hairline).frame(width: 1)
            }
            Group {
                switch pane {
                case .box: SearchView(app: app, model: search)
                case .senders: SendersView(model: senders)
                case .trash: TrashView(model: trash).id(Pane.trash)
                case .spam: TrashView(model: spam).id(Pane.spam)
                case .status: StatusView(app: app)
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: pane) { if case .box(let b) = pane { search.box = b } }
        .onChange(of: search.box) { if case .box = pane { pane = .box(search.box) } }  // 顯示全部 and Esc switch boxes from the list
        .modifier(AgentDrawer(model: agent, hasMessage: search.message != nil) { id in
            // The current box, not Inbox: changing the box clears the selection.
            if case .box = pane {} else { pane = .box(search.box) }
            search.selection = id
        })
        .overlay(alignment: .topLeading) {
            // Sits in the title bar row, right of the traffic lights.
            IconButton(symbol: "sidebar.left", help: showRail ? "隱藏側邊欄" : "顯示側邊欄") {
                withAnimation(.easeInOut(duration: 0.2)) { showRail.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .padding(.leading, 76)
            .padding(.top, -26)
        }
    }

    private func railItem(_ p: Pane) -> some View {
        RailItem(title: p.title, symbol: p.symbol, selected: pane == p) { pane = p }
            .keyboardShortcut(p.key, modifiers: .command)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Wordmark()
                .padding(.leading, 10)
                .padding(.top, 46)
                .padding(.bottom, 22)
            ForEach(Pane.mailboxes, id: \.self, content: railItem)
            Spacer().frame(height: 14)
            railItem(.senders)
            Spacer()
            railItem(.status)
            railItem(.settings)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 12)
        .frame(width: Theme.railWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Theme.paper)
    }
}

private struct RailItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Theme.paper : Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Theme.ink : (hovering ? Theme.hover : .clear), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
