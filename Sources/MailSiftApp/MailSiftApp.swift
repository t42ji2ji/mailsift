import MailCore
import SwiftUI

@main
struct MailSiftApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("MailSift", id: "main") {
            RootView(app: app)
                .frame(minWidth: 900, minHeight: 560)
                .task { app.start() }
        }
    }
}

struct RootView: View {
    let app: AppModel

    var body: some View {
        switch app.readiness {
        case .checking:
            ProgressView()
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
        VStack(spacing: 14) {
            if let failure {
                Text("無法讀取 Mail 資料").font(.title2)
                Text(failure).textSelection(.enabled)
            } else {
                Text("需要「完整磁碟取用權限」").font(.title2)
                Text("在「系統設定 › 隱私權與安全性 › 完整磁碟取用權限」開啟 MailSift，然後重新啟動 MailSift。")
                    .multilineTextAlignment(.center)
                Button("打開系統設定") { app.openFullDiskAccessSettings() }
                    .keyboardShortcut(.defaultAction)
            }
            Button("重新檢查") { app.start() }
        }
        .padding(40)
        .frame(maxWidth: 520)
    }
}

struct MainView: View {
    enum Pane: Hashable { case search, senders, status }

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
        NavigationSplitView {
            List(selection: $pane) {
                Label("搜尋", systemImage: "magnifyingglass").tag(Pane.search)
                Label("寄件者清理", systemImage: "person.2").tag(Pane.senders)
                Label("狀態與連接", systemImage: "gauge.with.dots.needle.33percent").tag(Pane.status)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch pane {
            case .search: SearchView(app: app, model: search)
            case .senders: SendersView(model: senders)
            case .status: StatusView(app: app)
            }
        }
    }
}
