import MailCore
import SwiftUI

struct SearchView: View {
    let app: AppModel
    @Bindable var model: SearchModel
    @State private var hasText = false
    @State private var clearToken = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                results
            }
            .frame(minWidth: 320, idealWidth: 400, maxWidth: 460)
            .background(Theme.paper)

            Rectangle().fill(Theme.hairline).frame(width: 1)

            MessageDetailView(model: model)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
            IMESearchField(prompt: "用一句話描述你要找的信", clearToken: clearToken, onEdit: { hasText = $0 }) { model.submit($0) }
                .frame(height: 22)
            if model.searching { ProgressView().controlSize(.mini) }
            if hasText {
                Button { clearToken += 1 } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .help("清除")
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.top, 42)
        .padding(.bottom, 8)
        .task(id: app.indexRevision) { model.loadRecent() }
    }

    @ViewBuilder private var results: some View {
        if let error = model.searchError {
            Message(symbol: "exclamationmark.circle", text: error)
        } else if model.query.isEmpty {
            HitList(model: model, sections: DateSection.group(model.recent), showMatch: false)
        } else if model.hits.isEmpty, !model.searching {
            Message(symbol: "tray", text: "沒有結果")
        } else {
            HitList(model: model, sections: [DateSection(title: "\(model.hits.count) 封結果", hits: model.hits)], showMatch: true)
        }
    }
}

/// A titled group of hits.
struct DateSection: Identifiable {
    let title: String
    let hits: [SearchHit]
    var id: String { title }

    /// 今天 / 昨天 / 本週 / 本月 / 更早, newest first, empty groups dropped.
    static func group(_ hits: [SearchHit], now: Date = .now) -> [DateSection] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let bounds: [(String, Date)] = [
            ("今天", today),
            ("昨天", cal.date(byAdding: .day, value: -1, to: today)!),
            ("本週", cal.date(byAdding: .day, value: -7, to: today)!),
            ("本月", cal.date(byAdding: .day, value: -30, to: today)!),
            ("更早", .distantPast),
        ]
        var buckets = Array(repeating: [SearchHit](), count: bounds.count)
        for hit in hits {
            let i = bounds.firstIndex { hit.meta.date >= $0.1 } ?? bounds.count - 1
            buckets[i].append(hit)
        }
        return zip(bounds, buckets).compactMap { $1.isEmpty ? nil : DateSection(title: $0.0, hits: $1) }
    }
}

/// Sectioned, keyboard-navigable list. With `preview`, long sections show their first rows and expand on demand.
private struct HitList: View {
    @Bindable var model: SearchModel
    let sections: [DateSection]
    let showMatch: Bool
    var preview = 5
    @State private var expanded = Set<String>()
    @FocusState private var focused: Bool

    private func visible(_ section: DateSection) -> [SearchHit] {
        showMatch || expanded.contains(section.id) ? section.hits : Array(section.hits.prefix(preview))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        header(section)
                        ForEach(visible(section)) { hit in
                            HitRow(hit: hit, selected: model.selection == hit.id, showMatch: showMatch)
                                .id(hit.id)
                                .onTapGesture {
                                    model.selection = hit.id
                                    focused = true
                                }
                        }
                        if !showMatch, section.hits.count > preview { toggle(section) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
        }
    }

    private func header(_ section: DateSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Eyebrow(section.title)
            Spacer()
            if !showMatch {
                Text(Fmt.count(section.hits.count)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func toggle(_ section: DateSection) -> some View {
        let open = expanded.contains(section.id)
        return Button {
            if open { expanded.remove(section.id) } else { expanded.insert(section.id) }
        } label: {
            HStack(spacing: 4) {
                Text(open ? "收合" : "顯示全部 \(Fmt.count(section.hits.count)) 封")
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = sections.flatMap(visible)
        guard !rows.isEmpty else { return .ignored }
        let current = rows.firstIndex { $0.id == model.selection } ?? (step > 0 ? -1 : rows.count)
        let next = min(max(current + step, 0), rows.count - 1)
        model.selection = rows[next].id
        proxy.scrollTo(rows[next].id)
        return .handled
    }
}

struct Message: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light))
            Text(text).font(.system(size: 13)).multilineTextAlignment(.center).textSelection(.enabled)
        }
        .foregroundStyle(Theme.muted)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HitRow: View {
    let hit: SearchHit
    let selected: Bool
    let showMatch: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(hit.meta.isRead ? Color.clear : Theme.ink)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Fmt.sender(hit.meta))
                        .font(.system(size: 13, weight: hit.meta.isRead ? .medium : .bold))
                        .lineLimit(1)
                    if hit.meta.isFlagged { Image(systemName: "flag.fill").font(.system(size: 9)) }
                    Spacer(minLength: 6)
                    Text(Fmt.short(hit.meta.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                Text(hit.meta.subject.isEmpty ? "（無主旨）" : hit.meta.subject)
                    .font(.system(size: 13))
                    .lineLimit(1)
                HStack(alignment: .top, spacing: 6) {
                    Text(hit.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if showMatch { MatchMark(match: hit.match) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(selected ? Theme.selected : (hovering ? Theme.fill : .clear), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Theme.ink).frame(width: 3).padding(.vertical, 10) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// How a hit was found: ● semantic, ○ keyword, ◐ both.
private struct MatchMark: View {
    let match: SearchHit.Match

    var body: some View {
        let (symbol, help): (String, String) = switch match {
        case .both: ("circle.lefthalf.filled", "語意＋關鍵字")
        case .semantic: ("circle.fill", "語意")
        case .keyword: ("circle", "關鍵字")
        }
        Image(systemName: symbol)
            .font(.system(size: 8))
            .foregroundStyle(Theme.faint)
            .padding(.top, 3)
            .help(help)
    }
}
