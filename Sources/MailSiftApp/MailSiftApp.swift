import MailCore
import SwiftUI

@main
struct MailSiftApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("MailSift", id: "main") {
            RootView(app: app)
                .frame(minWidth: 880, minHeight: 560)
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
    enum Pane: Hashable, CaseIterable {
        case search, senders, status

        var title: String {
            switch self {
            case .search: "搜尋"
            case .senders: "寄件者"
            case .status: "索引與連接"
            }
        }

        var symbol: String {
            switch self {
            case .search: "magnifyingglass"
            case .senders: "person.2"
            case .status: "circle.dashed"
            }
        }

        var key: KeyEquivalent {
            switch self {
            case .search: "1"
            case .senders: "2"
            case .status: "3"
            }
        }
    }

    let app: AppModel
    @State private var pane: Pane = .search
    @State private var search: SearchModel
    @State private var senders: SendersModel

    init(app: AppModel) {
        self.app = app
        _search = State(initialValue: SearchModel(app: app))
        _senders = State(initialValue: SendersModel(app: app))
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Group {
                switch pane {
                case .search: SearchView(app: app, model: search)
                case .senders: SendersView(model: senders)
                case .status: StatusView(app: app)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Wordmark()
                .padding(.leading, 10)
                .padding(.top, 46)
                .padding(.bottom, 22)
            ForEach(Pane.allCases, id: \.self) { p in
                RailItem(title: p.title, symbol: p.symbol, selected: pane == p) { pane = p }
                    .keyboardShortcut(p.key, modifiers: .command)
            }
            Spacer()
            IndexMeter(status: app.status, model: app.model)
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
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

/// Index progress in the rail: two thin bars, keyword and semantic.
private struct IndexMeter: View {
    let status: IndexStatus
    let model: AppModel.ModelState

    var body: some View {
        let total = max(status.totalMessages, 1)
        VStack(alignment: .leading, spacing: 10) {
            meter("關鍵字", status.keywordIndexed, total)
            meter("語意", status.vectorIndexed, total)
            if let note = Fmt.modelNote(model) {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
            }
        }
    }

    private func meter(_ label: String, _ n: Int, _ total: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(Int((Double(n) / Double(total) * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            ThinProgress(value: Double(n) / Double(total))
        }
    }
}
