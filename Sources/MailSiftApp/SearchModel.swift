import Foundation
import MailCore
import Observation

@MainActor @Observable
final class SearchModel {
    private(set) var query = ""
    private(set) var hits: [SearchHit] = []
    private(set) var searching = false
    private(set) var searchError: String?

    var selection: Int64? {
        didSet { if selection != oldValue { loadSelected() } }
    }
    private(set) var message: ParsedMessage?
    private(set) var loadingMessage = false
    private(set) var actionRunning = false
    var actionError: String?

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

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
        actionError = nil
        guard let id = selection, let lib = app.library else { return }
        loadingMessage = true
        messageTask = Task {
            let result = await Task.detached { Result { try lib.message(id: id) } }.value
            guard !Task.isCancelled, selection == id else { return }
            loadingMessage = false
            switch result {
            case .success(let m): message = m
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
            case .trash, .archive: break
            }
        }
        switch action {
        case .trash:
            hits.removeAll { $0.id == id }
            selection = nil
            app.refreshStatus()
        default:
            if let i = hits.firstIndex(where: { $0.id == id }) { update(&hits[i].meta) }
            if message?.meta.id == id { update(&message!.meta) }
        }
    }

    static func describe(_ error: Error) -> String {
        if case MailSourceError.automationDenied = error {
            return "MailSift 沒有控制 Mail 的權限。到「系統設定 › 隱私權與安全性 › 自動化」允許 MailSift 控制 Mail。"
        }
        return error.localizedDescription
    }
}
