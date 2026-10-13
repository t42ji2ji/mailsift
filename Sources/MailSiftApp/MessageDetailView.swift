import MailCore
import SwiftUI

struct MessageDetailView: View {
    @Bindable var model: SearchModel
    /// Shown as a back button when the message has taken over the list.
    var onBack: (() -> Void)? = nil
    @State private var plainText = false
    @AppStorage(SettingsView.loadRemoteKey) private var loadRemoteByDefault = true
    /// This message only; nil follows the setting.
    @State private var remoteOverride: Bool?
    private var remoteImages: Bool { remoteOverride ?? loadRemoteByDefault }
    @State private var confirmTrash = false
    @State private var showDetails = false

    var body: some View {
        Group {
            if let m = model.message {
                VStack(spacing: 0) {
                    actionBar(m.meta, hasHTML: m.html != nil)
                    if let error = model.actionError { ErrorStrip(text: error) }
                    if !plainText, let html = model.html ?? m.html {
                        header(m).padding(.horizontal, 36).padding(.bottom, 18)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        HTMLBodyView(html: html, allowRemote: remoteImages)
                            .padding(.top, 18)
                            .background(Color(white: 0.965))  // mail HTML assumes a light page, also in dark mode
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 26) {
                                header(m)
                                Rectangle().fill(Theme.hairline).frame(height: 1)
                                Text(m.bodyText.isEmpty ? AttributedString("（沒有文字內容）") : Linkify.attributed(m.bodyText))
                                    .font(.system(size: 14))
                                    .lineSpacing(5)
                                    .foregroundStyle(m.bodyText.isEmpty ? Theme.muted : Theme.ink)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, 36)
                            .padding(.bottom, 40)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else if model.loadingMessage {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.actionError {
                Message(symbol: "exclamationmark.circle", text: error)
            } else {
                Image(systemName: "envelope")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.message?.meta.id) {
            plainText = false
            remoteOverride = nil
            showDetails = false
        }
        .confirmationDialog("將這封郵件移到垃圾桶？", isPresented: $confirmTrash) {
            Button("移到垃圾桶", role: .destructive) { model.perform(.trash) }
        }
    }

    private func header(_ m: ParsedMessage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(m.meta.subject.isEmpty ? "（無主旨）" : m.meta.subject)
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                IconButton(symbol: m.meta.isFlagged ? "flag.fill" : "flag", help: m.meta.isFlagged ? "移除旗標" : "加旗標",
                           tint: m.meta.isFlagged ? Theme.flag : nil) {
                    model.perform(m.meta.isFlagged ? .unflag : .flag)
                }
                .disabled(model.actionRunning)
            }
                .textSelection(.enabled)
            HStack(alignment: showDetails ? .top : .center, spacing: 12) {
                Monogram(name: Fmt.sender(m.meta))
                VStack(alignment: .leading, spacing: 3) {
                    Button { showDetails.toggle() } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Fmt.sender(m.meta)).font(.system(size: 13, weight: .semibold))
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                            Spacer(minLength: 12)
                            Text(showDetails ? Fmt.date.string(from: m.meta.date) : Fmt.short(m.meta.date))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showDetails ? "收合寄件資訊" : "顯示寄件資訊")
                    if showDetails {
                        VStack(alignment: .leading, spacing: 3) {
                            if !m.meta.senderName.isEmpty { Text(m.meta.senderAddress) }
                            Text("給 " + (m.to.isEmpty ? "—" : m.to.joined(separator: ", ")))
                            if !m.cc.isEmpty { Text("副本 " + m.cc.joined(separator: ", ")) }
                            Text(m.meta.mailbox.account)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                    }
                }
            }
            AttachmentStrip(message: m, library: model.library)
        }
        .padding(.top, 6)
    }

    private func actionBar(_ meta: MessageMeta, hasHTML: Bool) -> some View {
        HStack(spacing: 4) {
            if let onBack { IconButton(symbol: "chevron.left", help: "回到列表", action: onBack) }
            Spacer()
            if model.actionRunning { ProgressView().controlSize(.mini).padding(.trailing, 6) }
            if hasHTML {
                if !plainText {
                    IconButton(symbol: remoteImages ? "photo.fill" : "photo", help: remoteImages ? "封鎖遠端圖片" : "載入遠端圖片", active: remoteImages) {
                        remoteOverride = !remoteImages
                    }
                }
                IconButton(symbol: "text.alignleft", help: plainText ? "顯示原始版面" : "顯示純文字", active: plainText) { plainText.toggle() }
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 4)
            }
            IconButton(symbol: "archivebox", help: "封存") { model.perform(.archive) }
            IconButton(symbol: "xmark.bin", help: "標為垃圾郵件") { model.perform(.junk) }
            IconButton(symbol: meta.isRead ? "envelope.badge" : "envelope.open", help: meta.isRead ? "標為未讀" : "標為已讀") {
                model.perform(meta.isRead ? .markUnread : .markRead)
            }
            IconButton(symbol: "trash", help: "移到垃圾桶") { confirmTrash = true }
        }
        .disabled(model.actionRunning)
        .padding(.horizontal, 16)
        .padding(.top, 38)
        .padding(.bottom, 14)
    }
}

struct ErrorStrip: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(10)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.radius))
        .hairlineBorder()
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}
