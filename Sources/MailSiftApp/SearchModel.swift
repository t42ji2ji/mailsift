import Foundation
import MailCore
import Observation

@MainActor @Observable
final class SearchModel {
    private(set) var query = ""
    private(set) var hits: [SearchHit] = []
    /// Results shown newest first instead of by relevance; each new search starts by relevance.
    var newestFirst = false
    /// Newest mail per mailbox while the query is empty, paged in as the list scrolls.
    /// Inbox holds only read, unflagged mail: unread and flagged mail sit above it.
    private(set) var rows: [BrowseBox: [SearchHit]] = [:]
    /// The newest unread inbox mail, on top; the unread box has all of it. A message read while open stays until
    /// another one is selected.
    private(set) var unread: [SearchHit] = []
    private(set) var unreadCount = 0
    static let unreadPreview = 10
    /// Inbox under the unread section: flagged mail pinned, then the rest. Each message appears once.
    var pinned: [SearchHit] { leavingOutUnread(rows[.flagged, default: []]) }
    var feed: [SearchHit] { leavingOutUnread(rows[.inbox, default: []]) }
    /// What the open box shows, top to bottom.
    var recent: [SearchHit] { box == .inbox ? unread + pinned + feed : rows[box, default: []] }

    private func leavingOutUnread(_ hits: [SearchHit]) -> [SearchHit] {
        let ids = Set(unread.map(\.id))
        return hits.filter { !ids.contains($0.id) }
    }
    private(set) var searching = false
    /// Reads of list rows still in flight.
    private(set) var pendingLoads = 0
    private(set) var searchError: String?

    var selection: Int64? {
        didSet {
            guard selection != oldValue else { return }
            settle(oldValue)
            loadSelected()
        }
    }
    private(set) var message: ParsedMessage?
    /// The message HTML with `cid:` images inlined as data URIs (nil until resolved or when there is no HTML).
    private(set) var html: String?
    private(set) var loadingMessage = false
    /// The open message's conversation, oldest first; empty or one message when it stands alone.
    private(set) var thread: [ParsedMessage] = []
    private(set) var actionRunning = false
    var actionError: String?
    /// The last message moved to Trash or Spam, offered back in a pill under the list for a few seconds.
    private(set) var undo: Undo?
    @ObservationIgnored private var undoTimer: Task<Void, Never>?

    struct Undo: Equatable {
        let meta: MessageMeta
        let action: MailAction
        /// Set while restoring, or when the restore failed.
        var status: String?
    }

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var exhausted: Set<BrowseBox> = []
    @ObservationIgnored private var paging: Set<BrowseBox> = []
    /// Each box keeps its own selection, so going back to one finds it as it was left.
    @ObservationIgnored private var selections: [BrowseBox: Int64] = [:]
    private static let page = 100

    init(app: AppModel) { self.app = app }

    /// Accounts with indexed mail, most mail first.
    private(set) var accounts: [String] = []
    /// Accounts the mail client has but whose mail isn't here yet.
    private(set) var syncingAccounts: [String] = []
    /// Accounts left out of every box and search. Saved as hidden, so a newly added account shows up.
    var hiddenAccounts = Set(UserDefaults.standard.stringArray(forKey: "hiddenAccounts") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(hiddenAccounts), forKey: "hiddenAccounts")
            rows = [:]
            exhausted = []
            loadRecent()
            submit(query)
        }
    }
    /// The accounts to show, or nil for all.
    private var shownAccounts: [String]? {
        let hidden = hiddenAccounts.intersection(accounts)
        return hidden.isEmpty ? nil : accounts.filter { !hidden.contains($0) }
    }

    var library: MailLibrary? { app.library }

    /// Which mailbox the list browses while the query is empty.
    var box: BrowseBox = .inbox {
        didSet {
            guard box != oldValue else { return }
            selections[oldValue] = selection
            selection = selections[box]
            if rows[box] == nil || box == .unread, let lib = app.library { load(box, lib) }  // unread mail changes as it is read
            loadCounts()
        }
    }

    /// Topic the boxes are narrowed to; nil is every topic.
    var category: String? {
        didSet {
            guard category != oldValue else { return }
            rows = [:]
            exhausted = []
            loadRecent()
        }
    }
    /// Messages per category id in the open box.
    private(set) var categoryCounts: [String: Int] = [:]
    /// Every category in display order, hidden ones included.
    private(set) var categories: [MailCategory] = []

    /// Saves categories edited in Settings; a hidden category stops narrowing the list.
    func saveCategories(_ edited: [MailCategory]) {
        guard let lib = app.library else { return }
        let relabel = edited.filter { !$0.description.isEmpty }.map { [$0.id, $0.description] }
            != categories.filter { !$0.description.isEmpty }.map { [$0.id, $0.description] }
        try? lib.saveCategories(edited)
        categories = lib.categories()
        if let category, categories.first(where: { $0.id == category })?.hidden != false { self.category = nil }
        if relabel { app.resync() }
    }

    /// Reloads unread mail, Inbox, the pinned flagged mail and the open box, keeping as many rows as each already has.
    func loadRecent() {
        guard let lib = app.library else { return }
        pendingLoads += 1
        Task {
            defer { pendingLoads -= 1 }
            // Listing accounts groups every message: done off the main thread, before the boxes that filter by them.
            let (indexed, syncing) = await Task.detached {
                let accounts = lib.accounts()
                return (accounts, lib.syncingAccounts(indexed: accounts))
            }.value
            // Assigned only when changed: every assignment redraws the list.
            if indexed != accounts { accounts = indexed }
            if syncing != syncingAccounts { syncingAccounts = syncing }
            loadCounts()
            loadUnread(lib)
            for box in Set([.inbox, .flagged, box]) { load(box, lib) }
        }
    }

    private func loadUnread(_ lib: MailLibrary) {
        let only = shownAccounts
        let category = category
        let limit = Self.unreadPreview
        pendingLoads += 1
        Task {
            defer { pendingLoads -= 1 }
            var (fresh, count) = await Task.detached {
                (lib.recent(.unread, limit: limit, accounts: only, category: category), lib.count(.unread, accounts: only, category: category))
            }.value
            guard category == self.category else { return }
            keepOpen(&fresh, from: unread)
            if fresh.map(\.meta) != unread.map(\.meta) { unread = fresh }
            if count != unreadCount { unreadCount = count }
        }
    }

    /// The open message was unread when opened: it stays put until another is selected. Its row keeps what it shows
    /// now, since a read that started before opening it may have missed it being marked read.
    private func keepOpen(_ fresh: inout [SearchHit], from old: [SearchHit]) {
        guard let id = selection, let open = old.first(where: { $0.id == id }) else { return }
        if let i = fresh.firstIndex(where: { $0.id == id }) {
            fresh[i] = open
        } else {
            fresh.append(open)
            fresh.sort { $0.meta.date > $1.meta.date }
        }
    }

    private func load(_ box: BrowseBox, _ lib: MailLibrary) {
        let only = shownAccounts
        let category = category
        // Flagged mail loads whole (a negative LIMIT is none in SQLite): the pinned section counts it.
        let limit = box == .flagged ? -1 : max(rows[box]?.count ?? 0, Self.page)
        pendingLoads += 1
        Task {
            defer { pendingLoads -= 1 }
            var fresh = await Task.detached {
                lib.recent(box, limit: limit, excludingFlagged: box == .inbox, isRead: box == .inbox ? true : nil, accounts: only,
                           category: category)
            }.value
            guard category == self.category else { return }
            if box == .unread { keepOpen(&fresh, from: rows[box, default: []]) }
            if fresh.map(\.meta) != rows[box]?.map(\.meta) { rows[box] = fresh }
            if box == .flagged || fresh.count < limit { exhausted.insert(box) } else { exhausted.remove(box) }
        }
    }

    private func loadCounts() {
        guard let lib = app.library else { return }
        let fresh = lib.categories()
        if fresh != categories { categories = fresh }
        let box = box
        let only = shownAccounts
        Task {
            let counts = await Task.detached { lib.categoryCounts(box, accounts: only) }.value
            guard box == self.box else { return }
            if counts != categoryCounts { categoryCounts = counts }
        }
    }

    /// Appends the next page of the open box; called when the list scrolls to its end.
    func loadMore() {
        let box = box
        guard let lib = app.library, let loaded = rows[box]?.count, !exhausted.contains(box), !paging.contains(box) else { return }
        paging.insert(box)
        let page = Self.page
        let only = shownAccounts
        let category = category
        pendingLoads += 1
        Task {
            defer { pendingLoads -= 1 }
            let next = await Task.detached {
                lib.recent(box, limit: page, offset: loaded, excludingFlagged: box == .inbox, isRead: box == .inbox ? true : nil, accounts: only,
                           category: category)
            }.value
            paging.remove(box)
            guard category == self.category else { return }
            if next.count < page { exhausted.insert(box) }
            let seen = Set(rows[box, default: []].map(\.id))
            rows[box, default: []] += next.filter { !seen.contains($0.id) }
        }
    }

    /// A message read while open leaves the unread section once another one is selected, and drops into its place below.
    private func settle(_ id: Int64?) {
        guard let id, let hit = (unread + rows[.unread, default: []]).first(where: { $0.id == id }), hit.meta.isRead else { return }
        unread.removeAll { $0.id == id }
        rows[.unread]?.removeAll { $0.id == id }
        loadRecent()
    }

    /// Called by the search field with committed (non-composing) text only.
    func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        if text != query { newestFirst = false }
        query = text
        searchError = nil
        guard !text.isEmpty, let lib = app.library else {
            hits = []
            searching = false
            return
        }
        searching = true
        let filter = SearchFilter(accounts: shownAccounts)
        searchTask = Task {
            do {
                let result = try await lib.search(text, filter: filter, limit: 100)
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
        thread = []
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
                if !m.meta.isRead { read(id, lib) }  // opening reads it, as in Mail
                Task {
                    let conversation = await Task.detached { (try? lib.thread(id)) ?? [] }.value
                    if selection == id { thread = conversation }
                }
                if m.html != nil, m.attachments.contains(where: { $0.contentID != nil && $0.isDownloaded }) {
                    let resolved = await Task.detached { Self.inlineImages(m, lib) }.value
                    if selection == id { html = resolved }
                }
            case .failure(let e): actionError = e.localizedDescription
            }
        }
    }

    /// Set by the main view: asks the assistant to draft a reply to this message.
    @ObservationIgnored var requestDraft: ((Int64) -> Void)?

    /// Opens a reply/forward window in Mail for the open message, or for `id` (a row right-clicked in the list).
    func compose(_ kind: ComposeKind, on id: Int64? = nil, body: String? = nil) {
        guard let id = id ?? selection, let lib = app.library else { return }
        actionError = nil
        Task {
            do { try await lib.compose(kind, id: id, body: body) } catch { actionError = Self.describe(error) }
        }
    }

    func perform(_ action: MailAction, on id: Int64? = nil) {
        guard let id = id ?? selection, let lib = app.library, !actionRunning else { return }
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

    /// Marks an opened message read. Not held up by, nor holding up, other actions: the next message may be opened
    /// before Mail answers.
    private func read(_ id: Int64, _ lib: MailLibrary) {
        Task {
            do {
                let report = try await lib.perform(.markRead, ids: [id])
                if let why = report.failed[id] {
                    if selection == id { actionError = why }
                    return
                }
                apply(.markRead, to: id)
            } catch {
                if selection == id { actionError = Self.describe(error) }
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
            case .trash, .archive, .restore, .junk, .deletePermanently: break
            }
        }
        switch action {
        case .trash, .junk:
            if let meta = (hits + rows.values.joined() + unread).first(where: { $0.id == id })?.meta ?? message?.meta {
                offerUndo(Undo(meta: meta, action: action))
            }
            hits.removeAll { $0.id == id }
            for b in rows.keys { rows[b]!.removeAll { $0.id == id } }
            unread.removeAll { $0.id == id }
            if let lib = app.library { loadUnread(lib) }  // its count
            if selection == id { selection = nil }
            app.refreshStatus()
        default:
            if let i = hits.firstIndex(where: { $0.id == id }) { update(&hits[i].meta) }
            for b in rows.keys {
                if let i = rows[b]!.firstIndex(where: { $0.id == id }) { update(&rows[b]![i].meta) }
            }
            if let i = unread.firstIndex(where: { $0.id == id }) { update(&unread[i].meta) }
            if message?.meta.id == id { update(&message!.meta) }
            if [.flag, .unflag, .markUnread].contains(action) { loadRecent() }  // moves it between the sections
            if action == .markRead, id != selection { settle(id) }  // read after another was opened
        }
    }

    private func offerUndo(_ u: Undo?, for seconds: Int = 8) {
        undo = u
        undoTimer?.cancel()
        guard u != nil else { return }
        undoTimer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { undo = nil }
        }
    }

    /// Moves the message in the pill back to the inbox. Mail gives the moved copy a new id, so it is found again
    /// in Trash (or Spam) by account, sender, subject and date, waiting a moment for Mail to write it there.
    func undoLast() {
        guard var u = undo, u.status == nil, let lib = app.library else { return }
        undoTimer?.cancel()
        u.status = "復原中…"
        undo = u
        let m = u.meta
        let role: MailboxRole = u.action == .junk ? .spam : .trash
        Task {
            for _ in 0..<10 {
                let copy = await Task.detached {
                    lib.mailbox(role).first {
                        $0.mailbox.account == m.mailbox.account && $0.senderAddress == m.senderAddress
                            && $0.subject == m.subject && abs($0.date.timeIntervalSince(m.date)) < 1
                    }
                }.value
                if let copy {
                    do {
                        let report = try await lib.perform(.restore, ids: [copy.id])
                        if let why = report.failed[copy.id] { u.status = why; offerUndo(u, for: 5); return }
                    } catch {
                        u.status = Self.describe(error)
                        offerUndo(u, for: 5)
                        return
                    }
                    offerUndo(nil)
                    app.resync()  // restored mail returns to the index
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            u.status = role == .spam ? "在垃圾郵件裡找不到這封信" : "在垃圾桶裡找不到這封信"
            offerUndo(u, for: 5)
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
