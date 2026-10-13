import MailCore
import SwiftUI

struct SearchView: View {
    let app: AppModel
    @Bindable var model: SearchModel
    @FocusState private var listFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                Rectangle().fill(Theme.hairline).frame(height: 1)
                results
            }
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 460)
            .background(Theme.paper)

            Rectangle().fill(Theme.hairline).frame(width: 1)

            MessageDetailView(model: model)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
            IMESearchField(prompt: "用一句話描述你要找的信") { model.submit($0) }
                .frame(height: 22)
            if model.searching { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.top, 42)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var results: some View {
        if let error = model.searchError {
            Message(symbol: "exclamationmark.circle", text: error)
        } else if model.query.isEmpty {
            Color.clear
        } else if model.hits.isEmpty, !model.searching {
            Message(symbol: "tray", text: "沒有結果")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(model.hits.count) 封").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.hits) { hit in
                                HitRow(hit: hit, selected: model.selection == hit.id)
                                    .id(hit.id)
                                    .onTapGesture {
                                        model.selection = hit.id
                                        listFocused = true
                                    }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .onKeyPress(.downArrow) { move(1, proxy) }
                    .onKeyPress(.upArrow) { move(-1, proxy) }
                }
            }
        }
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !model.hits.isEmpty else { return .ignored }
        let current = model.hits.firstIndex { $0.id == model.selection } ?? (step > 0 ? -1 : model.hits.count)
        let next = min(max(current + step, 0), model.hits.count - 1)
        model.selection = model.hits[next].id
        proxy.scrollTo(model.hits[next].id)
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
                    MatchMark(match: hit.match)
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
