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
    @State private var showDetails = false
    @State private var unsubscribe: UnsubscribeState = .idle
    /// Shows the open message as sent, quoted history and all, instead of its conversation.
    @State private var showOriginal = false
    private var conversation: Bool { model.thread.count > 1 && !showOriginal }

    var body: some View {
        Group {
            if let m = model.message {
                VStack(spacing: 0) {
                    actionBar(m, hasHTML: m.html != nil)
                    if let error = model.actionError { ErrorStrip(text: error) }
                    if conversation {
                        ConversationView(open: m, thread: model.thread, library: model.library) { subjectLine(m) }
                            .id(m.meta.id)
                    } else if !plainText, let html = model.html ?? m.html {
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
                            .overlayScroller()
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
            unsubscribe = .idle
            showOriginal = false
        }
    }

    private func subjectLine(_ m: ParsedMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(m.meta.subject.isEmpty ? "（無主旨）" : m.meta.subject)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(symbol: m.meta.isFlagged ? "flag.fill" : "flag", help: m.meta.isFlagged ? "移除旗標（S）" : "加旗標（S）",
                       tint: m.meta.isFlagged ? Theme.flag : nil) {
                model.perform(m.meta.isFlagged ? .unflag : .flag)
            }
            .disabled(model.actionRunning)
        }
    }

    private func header(_ m: ParsedMessage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            subjectLine(m)
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
                    } else {
                        Text("給 " + (m.to.isEmpty ? "—" : m.to.joined(separator: ", ")))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
            }
            AttachmentStrip(message: m, library: model.library)
        }
        .padding(.top, 6)
    }

    private func actionBar(_ m: ParsedMessage, hasHTML: Bool) -> some View {
        let meta = m.meta
        return HStack(spacing: 4) {
            if let onBack { IconButton(symbol: "chevron.left", help: "回到列表", action: onBack) }
            IconButton(symbol: "arrowshape.turn.up.left", help: "回覆（⌘R）") { model.compose(.reply) }
                .keyboardShortcut("r", modifiers: .command)
            IconButton(symbol: "arrowshape.turn.up.left.2", help: "全部回覆（⇧⌘R）") { model.compose(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            IconButton(symbol: "arrowshape.turn.up.right", help: "轉寄（⇧⌘F）") { model.compose(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            if let draft = model.requestDraft {
                IconButton(symbol: "sparkles", help: "請助理擬回覆") { draft(meta.id) }
            }
            Spacer()
            if model.actionRunning { ProgressView().controlSize(.mini).padding(.trailing, 6) }
            if model.thread.count > 1 {
                IconButton(symbol: "bubble.left.and.text.bubble.right", help: showOriginal ? "以對話顯示" : "顯示原始信件",
                           active: !showOriginal) { showOriginal.toggle() }
                if conversation || !hasHTML { Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 4) }
            }
            if hasHTML, !conversation {
                if !plainText {
                    IconButton(symbol: remoteImages ? "photo.fill" : "photo", help: remoteImages ? "封鎖遠端圖片" : "載入遠端圖片", active: remoteImages) {
                        remoteOverride = !remoteImages
                    }
                }
                IconButton(symbol: "text.alignleft", help: plainText ? "顯示原始版面" : "顯示純文字", active: plainText) { plainText.toggle() }
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 4)
            }
            if let u = m.unsubscribe {
                unsubscribeButton(u)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 4)
            }
            IconButton(symbol: "archivebox", help: "封存（E）") { model.perform(.archive) }
            IconButton(symbol: "xmark.bin", help: "標為垃圾郵件") { model.perform(.junk) }
            IconButton(symbol: meta.isRead ? "envelope.badge" : "envelope.open", help: meta.isRead ? "標為未讀（U）" : "標為已讀（U）") {
                model.perform(meta.isRead ? .markUnread : .markRead)
            }
            IconButton(symbol: "trash", help: "移到垃圾桶（#）") { model.perform(.trash) }
        }
        .disabled(model.actionRunning)
        .padding(.horizontal, 16)
        .padding(.top, 38)
        .padding(.bottom, 14)
    }
}

/// A conversation as one card per message, oldest first. The open message and the newest are expanded; the others
/// show a line and expand on click.
private struct ConversationView<Subject: View>: View {
    let open: ParsedMessage
    let thread: [ParsedMessage]
    let library: MailLibrary?
    @ViewBuilder let subject: () -> Subject
    @State private var expanded: Set<Int64> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    subject().textSelection(.enabled).padding(.bottom, 8)
                    ForEach(thread, id: \.meta.id) { m in
                        card(m).id(m.meta.id)
                    }
                }
                .overlayScroller()
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 6)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                expanded = [open.meta.id, thread.last?.meta.id ?? open.meta.id]
                proxy.scrollTo(open.meta.id, anchor: .top)
            }
        }
    }

    private func card(_ m: ParsedMessage) -> some View {
        let isOpen = expanded.contains(m.meta.id)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if isOpen { expanded.remove(m.meta.id) } else { expanded.insert(m.meta.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Fmt.sender(m.meta)).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
                    if !isOpen {
                        Text(Self.firstLine(m.bodyText)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(Fmt.short(m.meta.date)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Text(m.bodyText.isEmpty ? AttributedString("（沒有文字內容）") : Linkify.attributed(m.bodyText))
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(m.bodyText.isEmpty ? Theme.muted : Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if m.meta.id == open.meta.id { AttachmentStrip(message: open, library: library) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(m.meta.id == open.meta.id ? Theme.selected : Theme.fill, in: RoundedRectangle(cornerRadius: 10))
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

private enum UnsubscribeState: Equatable {
    case idle, running, done, failed
}

extension MessageDetailView {
    /// One-click lists are unsubscribed here; others open their page, or a prefilled mail to the list.
    fileprivate func unsubscribeButton(_ u: Unsubscribe) -> some View {
        Button {
            if u.oneClick {
                unsubscribe = .running
                Task {
                    do {
                        try await u.postOneClick()
                        unsubscribe = .done
                    } catch {
                        unsubscribe = .failed
                    }
                }
            } else if let url = u.web ?? u.mailto {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 5) {
                if unsubscribe == .running { ProgressView().controlSize(.mini) }
                Text(unsubscribe == .done ? "已退訂" : unsubscribe == .failed ? "退訂失敗，再試一次" : "退訂")
                if !u.oneClick { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)) }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(unsubscribe == .done ? Theme.muted : Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(unsubscribe == .running || unsubscribe == .done)
        .help(u.oneClick ? "直接退訂這份郵件清單" : u.web != nil ? "在瀏覽器開啟退訂頁面" : "開一封退訂信，寄出才會生效")
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
