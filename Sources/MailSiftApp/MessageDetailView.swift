import MailCore
import SwiftUI

struct MessageDetailView: View {
    @Bindable var model: SearchModel
    @State private var showHTML = false
    @State private var confirmTrash = false

    var body: some View {
        Group {
            if let m = model.message {
                VStack(alignment: .leading, spacing: 0) {
                    headers(m).padding(12)
                    if let error = model.actionError { errorLine(error) }
                    Divider()
                    if showHTML, let html = m.html {
                        HTMLBodyView(html: html)
                    } else {
                        ScrollView {
                            Text(m.bodyText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                }
            } else if model.loadingMessage {
                ProgressView()
            } else if let error = model.actionError {
                errorLine(error)
            } else {
                Color.clear
            }
        }
        .toolbar { if model.message != nil { actions } }
        .confirmationDialog("將這封郵件移到垃圾桶？", isPresented: $confirmTrash) {
            Button("移到垃圾桶", role: .destructive) { model.perform(.trash) }
        }
    }

    private func headers(_ m: ParsedMessage) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            row("寄件者", m.meta.senderName.isEmpty ? m.meta.senderAddress : "\(m.meta.senderName) <\(m.meta.senderAddress)>")
            row("收件者", m.to.joined(separator: ", "))
            if !m.cc.isEmpty { row("副本", m.cc.joined(separator: ", ")) }
            row("日期", Fmt.date.string(from: m.meta.date))
            row("信箱", "\(m.meta.mailbox.account) · \(m.meta.mailbox.name)")
            row("主旨", m.meta.subject).fontWeight(.semibold)
        }
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
        }
    }

    private func errorLine(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    @ToolbarContentBuilder private var actions: some ToolbarContent {
        let meta = model.message!.meta
        ToolbarItemGroup {
            if model.message?.html != nil {
                Toggle(isOn: $showHTML) { Label("HTML", systemImage: "doc.richtext") }
                    .help("HTML")
            }
            Button { confirmTrash = true } label: { Label("移到垃圾桶", systemImage: "trash") }
                .help("移到垃圾桶")
            Button { model.perform(.archive) } label: { Label("封存", systemImage: "archivebox") }
                .help("封存")
            Button { model.perform(meta.isRead ? .markUnread : .markRead) } label: {
                Label(meta.isRead ? "標為未讀" : "標為已讀", systemImage: meta.isRead ? "envelope.badge" : "envelope.open")
            }
            .help(meta.isRead ? "標為未讀" : "標為已讀")
            Button { model.perform(meta.isFlagged ? .unflag : .flag) } label: {
                Label(meta.isFlagged ? "移除旗標" : "加旗標", systemImage: meta.isFlagged ? "flag.slash" : "flag")
            }
            .help(meta.isFlagged ? "移除旗標" : "加旗標")
        }
    }
}
