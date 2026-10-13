import Foundation
import MailCore
import Observation

@MainActor @Observable
final class SearchModel {
    private(set) var query = ""
    private(set) var hits: [SearchHit] = []
    /// Newest mail, shown while the query is empty.
    private(set) var recent: [SearchHit] = []
    private(set) var searching = false
    private(set) var searchError: String?

    var selection: Int64? {
        didSet { if selection != oldValue { loadSelected() } }
    }
    private(set) var message: ParsedMessage?
    /// The message HTML with `cid:` images inlined as data URIs (nil until resolved or when there is no HTML).
    private(set) var html: String?
    private(set) var loadingMessage = false
    private(set) var actionRunning = false
    var actionError: String?

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    var library: MailLibrary? { app.library }

    /// Which mailbox the list browses while the query is empty.
    var box: BrowseBox = .inbox {
        didSet {
            guard box != oldValue else { return }
            recent = []
            selection = nil
            loadRecent()
        }
    }

    func loadRecent() {
        guard let lib = app.library else { return }
        let box = box
        Task {
            let rows = await Task.detached { lib.recent(box) }.value
            if box == self.box { recent = rows }
        }
    }

    /// Called by the search field with committed (non-composing) text only.
    func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        query = text
        searchError = nil
        guard !text.isEmpty, let lib = app.library else {
            hits = []
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            do {
                let result = try await lib.search(text, limit: 100)
                guard !Task.isCancelled, text == query else { return }
                hits = result
            } catch {
                guard !Task.isCancelled, text == query else { return }
                hits = []
                searchError = error.localizedDescription
            }
            searching = false
        }
    }

    private func loadSelected() {
        messageTask?.cancel()
        message = nil
        html = nil
        actionError = nil
        guard let id = selection, let lib = app.library else { return }
        loadingMessage = true
        messageTask = Task {
            let result = await Task.detached { Result { try lib.message(id: id) } }.value
            guard !Task.isCancelled, selection == id else { return }
            loadingMessage = false
            switch result {
            case .success(let m):
                message = m
                html = m.html
                if m.html != nil, m.attachments.contains(where: { $0.contentID != nil && $0.isDownloaded }) {
                    let resolved = await Task.detached { Self.inlineImages(m, lib) }.value
                    if selection == id { html = resolved }
                }
                if !m.meta.isRead { perform(.markRead) }  // opening reads it, as in Mail
            case .failure(let e): actionError = e.localizedDescription
            }
        }
    }

    func perform(_ action: MailAction) {
        guard let id = selection, let lib = app.library, !actionRunning else { return }
        actionRunning = true
        actionError = nil
        Task {
            defer { actionRunning = false }
            do {
                let report = try await lib.perform(action, ids: [id])
                if let why = report.failed[id] {
                    actionError = why
                    return
                }
                apply(action, to: id)
            } catch {
                actionError = Self.describe(error)
            }
        }
    }

    /// Mirrors a successful action in the visible list and detail.
    private func apply(_ action: MailAction, to id: Int64) {
        func update(_ meta: inout MessageMeta) {
            switch action {
            case .markRead: meta.isRead = true
            case .markUnread: meta.isRead = false
            case .flag: meta.isFlagged = true
            case .unflag: meta.isFlagged = false
            case .trash, .archive, .restore, .junk: break
            }
        }
        switch action {
        case .trash, .junk:
            hits.removeAll { $0.id == id }
            recent.removeAll { $0.id == id }
            selection = nil
            app.refreshStatus()
        default:
            if let i = hits.firstIndex(where: { $0.id == id }) { update(&hits[i].meta) }
            if let i = recent.firstIndex(where: { $0.id == id }) { update(&recent[i].meta) }
            if message?.meta.id == id { update(&message!.meta) }
        }
    }

    /// Replaces `cid:` references with data URIs so WebKit can show inline images without file access.
    nonisolated static func inlineImages(_ m: ParsedMessage, _ lib: MailLibrary) -> String? {
        guard var html = m.html else { return nil }
        for a in m.attachments {
            guard let cid = a.contentID, a.isDownloaded, html.contains("cid:\(cid)"),
                  let url = try? lib.attachmentFile(m.meta, a), let data = try? Data(contentsOf: url) else { continue }
            html = html.replacingOccurrences(of: "cid:\(cid)", with: "data:\(a.mimeType);base64,\(data.base64EncodedString())")
        }
        return html
    }

    static func describe(_ error: Error) -> String {
        if case MailSourceError.automationDenied = error {
            return "MailSift 沒有控制 Mail 的權限。到「系統設定 › 隱私權與安全性 › 自動化」允許 MailSift 控制 Mail。"
        }
        return error.localizedDescription
    }
}
