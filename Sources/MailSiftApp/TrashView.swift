import MailCore
import Observation
import SwiftUI

@MainActor @Observable
final class TrashModel {
    private(set) var items: [MessageMeta] = []
    private(set) var loading = false
    var selection = Set<Int64>()
    private(set) var preview: ParsedMessage?
    private(set) var restoring: Int?
    var result: String?

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    func reload() {
        guard let lib = app.library else { return }
        loading = true
        Task {
            items = await Task.detached { lib.trash() }.value
            let ids = Set(items.map(\.id))
            selection = selection.filter { ids.contains($0) }
            loading = false
        }
    }

    /// Previews the single selected message (trashed mail isn't indexed, so it is parsed from Mail's files).
    func selectionChanged() {
        previewTask?.cancel()
        preview = nil
        guard selection.count == 1, let meta = items.first(where: { $0.id == selection.first }), let lib = app.library else { return }
        previewTask = Task {
            let parsed = await Task.detached { try? lib.source.parse(meta) }.value
            guard !Task.isCancelled else { return }
            preview = parsed
        }
    }

    func restore() {
        guard let lib = app.library, !selection.isEmpty else { return }
        let ids = Array(selection)
        restoring = ids.count
        result = nil
        Task {
            do {
                let r = try await lib.perform(.restore, ids: ids)
                result = "已還原 \(Fmt.count(r.succeeded.count)) 封" + (r.failed.isEmpty ? "" : " · 失敗 \(Fmt.count(r.failed.count)) 封")
            } catch {
                result = SearchModel.describe(error)
            }
            restoring = nil
            selection = []
            reload()
            app.resync()  // restored mail returns to the index
        }
    }
}

struct TrashView: View {
    @Bindable var model: TrashModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                list
            }
            .frame(minWidth: 320, idealWidth: 420, maxWidth: 520)
            .background(Theme.paper)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            preview
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .task { model.reload() }
        .onChange(of: model.selection) { model.selectionChanged() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("垃圾桶").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                Text(Fmt.count(model.items.count)).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 10) {
                Button(model.selection.isEmpty ? "還原" : "還原 · \(Fmt.count(model.selection.count)) 封") { model.restore() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(model.selection.isEmpty || model.restoring != nil)
                if model.restoring != nil { ProgressView().controlSize(.mini) }
                if let r = model.result { Text(r).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2) }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 44)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var list: some View {
        if model.items.isEmpty {
            Message(symbol: "trash", text: model.loading ? "讀取中" : "垃圾桶是空的")
        } else {
            List(model.items, selection: $model.selection) { meta in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(Fmt.sender(meta)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(Fmt.short(meta.date)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    Text(meta.subject.isEmpty ? "（無主旨）" : meta.subject).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var preview: some View {
        if let m = model.preview {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(m.meta.subject.isEmpty ? "（無主旨）" : m.meta.subject)
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(Fmt.sender(m.meta)) · \(Fmt.date.string(from: m.meta.date)) · \(m.meta.mailbox.account)")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    Text(Linkify.attributed(m.bodyText)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 44)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        } else if model.selection.count > 1 {
            Message(symbol: "square.stack", text: "已選 \(Fmt.count(model.selection.count)) 封")
        } else {
            Image(systemName: "trash").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
