import MailCore
import SwiftUI

struct SearchView: View {
    let app: AppModel
    @Bindable var model: SearchModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                IMESearchField(prompt: "搜尋郵件") { model.submit($0) }
                    .padding(8)
                Divider()
                results
                Divider()
                statusFooter
            }
            .frame(minWidth: 320, idealWidth: 420)

            MessageDetailView(model: model)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var results: some View {
        if let error = model.searchError {
            Text(error).foregroundStyle(.red).padding().frame(maxHeight: .infinity)
        } else if !model.query.isEmpty, model.hits.isEmpty, !model.searching {
            Text("沒有結果").foregroundStyle(.secondary).frame(maxHeight: .infinity)
        } else {
            List(model.hits, selection: $model.selection) { hit in
                HitRow(hit: hit)
            }
            .listStyle(.inset)
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 6) {
            if model.searching || app.status.phase == .syncing || app.status.phase == .embedding {
                ProgressView().controlSize(.small)
            }
            Text(Fmt.indexLine(app.status))
            if case .loading = app.model { Text("· 模型載入中") }
            if case .failed = app.model { Text("· 僅關鍵字").foregroundStyle(.orange) }
            Spacer()
            if !model.hits.isEmpty { Text("\(model.hits.count) 筆") }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

private struct HitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if !hit.meta.isRead { Circle().fill(.blue).frame(width: 6, height: 6) }
                Text(Fmt.sender(hit.meta)).fontWeight(hit.meta.isRead ? .regular : .semibold).lineLimit(1)
                if hit.meta.isFlagged { Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption) }
                Spacer()
                MatchBadge(match: hit.match)
                Text(Fmt.date.string(from: hit.meta.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(hit.meta.subject.isEmpty ? "（無主旨）" : hit.meta.subject).lineLimit(1)
            Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 3)
    }
}

private struct MatchBadge: View {
    let match: SearchHit.Match

    var body: some View {
        let (label, color): (String, Color) = switch match {
        case .both: ("語意＋關鍵字", .green)
        case .semantic: ("語意", .purple)
        case .keyword: ("關鍵字", .blue)
        }
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }
}
