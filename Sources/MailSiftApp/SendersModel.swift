import Foundation
import MailCore
import Observation

@MainActor @Observable
final class SendersModel {
    /// Senders at or above this count are highlighted as cleanup candidates.
    static let attentionCount = 50

    struct TrashPlan: Identifiable {
        let id = UUID()
        struct Line: Identifiable {
            var stat: SenderStat
            var ids: [Int64]
            var id: String { stat.id }
        }
        var lines: [Line]
        var total: Int { lines.reduce(0) { $0 + $1.ids.count } }
    }

    struct TrashResult {
        var succeeded: Int
        var failed: Int
        var firstFailure: String?
    }

    private(set) var all: [SenderStat] = []
    private(set) var accounts: [String] = []
    var account: String? { didSet { applySort() } }
    var sortOrder = [KeyPathComparator(\SenderStat.count, order: .reverse)] { didSet { applySort() } }
    private(set) var rows: [SenderStat] = []
    var selection = Set<String>()

    private(set) var loading = false

    enum Mode { case map, table }
    var mode: Mode = .map
    private(set) var map: SenderMap?
    private(set) var mapLoading = false

    /// Computed once per launch (a few seconds); the layout doesn't need to follow every new message.
    func loadMap() {
        guard map == nil, !mapLoading, let lib = app.library else { return }
        mapLoading = true
        Task {
            map = await Task.detached(priority: .userInitiated) { lib.senderMap() }.value
            mapLoading = false
        }
    }

    /// Message count of the selected senders.
    var selectedMessages: Int {
        all.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.count }
    }
    var plan: TrashPlan?
    private(set) var trashing: Int?
    var result: TrashResult?
    var error: String?

    @ObservationIgnored private let app: AppModel

    init(app: AppModel) { self.app = app }

    func reload() {
        guard let lib = app.library else { return }
        loading = true
        Task {
            all = await Task.detached { lib.senders(limit: 5000) }.value
            accounts = Array(Set(all.map(\.account))).sorted()
            if let account, !accounts.contains(account) { self.account = nil }
            let ids = Set(all.map(\.id))
            selection = selection.filter { ids.contains($0) }
            applySort()
            loading = false
        }
    }

    private func applySort() {
        let filtered = account.map { a in all.filter { $0.account == a } } ?? all
        rows = filtered.sorted(using: sortOrder)
    }

    /// Resolves the exact message ids per selected sender before asking for confirmation.
    func prepareTrash() {
        guard let lib = app.library else { return }
        let stats = all.filter { selection.contains($0.id) }
        guard !stats.isEmpty else { return }
        Task {
            let lines = await Task.detached {
                stats.map { TrashPlan.Line(stat: $0, ids: lib.messages(fromSender: $0.address, account: $0.account).map(\.id)) }
            }.value
            plan = TrashPlan(lines: lines.filter { !$0.ids.isEmpty })
        }
    }

    func confirmTrash() {
        guard let plan, let lib = app.library else { return }
        self.plan = nil
        let ids = plan.lines.flatMap(\.ids)
        guard !ids.isEmpty else { return }
        trashing = ids.count
        result = nil
        error = nil
        Task {
            do {
                let report = try await lib.perform(.trash, ids: ids)
                result = TrashResult(succeeded: report.succeeded.count, failed: report.failed.count,
                                     firstFailure: report.failed.values.first)
            } catch {
                self.error = SearchModel.describe(error)
            }
            trashing = nil
            selection = []
            app.refreshStatus()
            reload()
        }
    }
}
