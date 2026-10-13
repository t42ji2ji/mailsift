import Foundation
import MailCore
import Observation

@MainActor @Observable
final class SearchModel {
    private(set) var query = ""
    private(set) var hits: [SearchHit] = []
    /// Newest mail per mailbox while the query is empty, paged in as the list scrolls.
    /// Inbox leaves out flagged mail: that is pinned above it, from `rows[.flagged]`.
    private(set) var rows: [BrowseBox: [SearchHit]] = [:]
    /// What the open box shows, top to bottom.
    var recent: [SearchHit] { box == .inbox ? pinned + rows[.inbox, default: []] : rows[box, default: []] }
    var pinned: [SearchHit] { rows[.flagged, default: []] }
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
    @ObservationIgnored private var exhausted: Set<BrowseBox> = []
    @ObservationIgnored private var paging: Set<BrowseBox> = []
    /// Each box keeps its own selection, so going back to one finds it as it was left.
    @ObservationIgnored private var selections: [BrowseBox: Int64] = [:]
    private static let page = 100

    init(app: AppModel) { self.app = app }

    var library: MailLibrary? { app.library }

    /// Which mailbox the list browses while the query is empty.
    var box: BrowseBox = .inbox {
        didSet {
            guard box != oldValue else { return }
            selections[oldValue] = selection
            selection = selections[box]
            if rows[box] == nil { loadRecent() }
        }
    }

    /// Reloads Inbox, the pinned flagged mail and the open box, keeping as many rows as each already has.
    func loadRecent() {
        guard let lib = app.library else { return }
        for box in Set([.inbox, .flagged, box]) {
            // Flagged mail loads whole (a negative LIMIT is none in SQLite): the pinned section counts it.
            let limit = box == .flagged ? -1 : max(rows[box]?.count ?? 0, Self.page)
            Task {
                let fresh = await Task.detached { lib.recent(box, limit: limit, excludingFlagged: box == .inbox) }.value
                rows[box] = fresh
                if box == .flagged || fresh.count < limit { exhausted.insert(box) } else { exhausted.remove(box) }
            }
        }
    }

    /// Appends the next page of the open box; called when the list scrolls to its end.
    func loadMore() {
        let box = box
        guard let lib = app.library, let loaded = rows[box]?.count, !exhausted.contains(box), !paging.contains(box) else { return }
        paging.insert(box)
        let page = Self.page
        Task {
            let next = await Task.detached { lib.recent(box, limit: page, offset: loaded, excludingFlagged: box == .inbox) }.value
            paging.remove(box)
            if next.count < page { exhausted.insert(box) }
            let seen = Set(rows[box, default: []].map(\.id))
            rows[box, default: []] += next.filter { !seen.contains($0.id) }
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

    /// Set by the main view: asks the assistant to draft a reply to this message.
    @ObservationIgnored var requestDraft: ((Int64) -> Void)?

    /// Opens a reply/forward window in Mail for the open message.
    func compose(_ kind: ComposeKind, body: String? = nil) {
        guard let id = selection, let lib = app.library else { return }
        actionError = nil
        Task {
            do { try await lib.compose(kind, id: id, body: body) } catch { actionError = Self.describe(error) }
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
            for b in rows.keys { rows[b]!.removeAll { $0.id == id } }
            selection = nil
            app.refreshStatus()
        default:
            if let i = hits.firstIndex(where: { $0.id == id }) { update(&hits[i].meta) }
            for b in rows.keys {
                if let i = rows[b]!.firstIndex(where: { $0.id == id }) { update(&rows[b]![i].meta) }
            }
            if message?.meta.id == id { update(&message!.meta) }
            if action == .flag || action == .unflag { loadRecent() }  // moves it between the pinned section and the feed
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
