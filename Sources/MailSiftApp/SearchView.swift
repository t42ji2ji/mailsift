import MailCore
import SwiftUI

struct SearchView: View {
    let app: AppModel
    @Bindable var model: SearchModel
    @State private var hasText = false
    @State private var clearToken = 0
    /// Too narrow for list and message side by side: the open message slides over the list.
    @State private var narrow = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    searchBar
                    results
                        .animation(.easeInOut(duration: 0.22), value: model.box)
                }
                .frame(minWidth: 320, idealWidth: 400, maxWidth: narrow ? .infinity : 460)
                .background(Theme.paper)

                if !narrow {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    MessageDetailView(model: model)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.canvas)
                }
            }

            if narrow, model.selection != nil {
                MessageDetailView(model: model, onBack: { model.selection = nil })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.canvas)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.25), value: narrow && model.selection != nil)
        .onGeometryChange(for: Bool.self) { $0.size.width < 720 } action: { narrow = $0 }
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
        .overlay(alignment: .trailing) {
            IconButton(symbol: "square.and.pencil", help: "新郵件（⌘N）") { Compose.newMessage() }
                .keyboardShortcut("n", modifiers: .command)
                .offset(x: 38)
        }
        .padding(.leading, 14)
        .padding(.trailing, 52)
        .padding(.top, 42)
        .padding(.bottom, 8)
        .task(id: app.indexRevision) { model.loadRecent() }
    }

    @ViewBuilder private var results: some View {
        if let error = model.searchError {
            Message(symbol: "exclamationmark.circle", text: error)
        } else if model.query.isEmpty {
            // Inbox is the bottom layer and never leaves; other boxes slide in over it and back out.
            ZStack {
                HitList(model: model, sections: inboxSections, showMatch: false, active: model.box == .inbox)
                if model.box != .inbox {
                    VStack(spacing: 0) {
                        backRow
                        HitList(model: model, sections: DateSection.group(model.recent), showMatch: false)
                    }
                    .background(Theme.paper)
                    .id(model.box)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
                }
            }
        } else if model.hits.isEmpty, !model.searching {
            Message(symbol: "tray", text: "沒有結果")
        } else {
            HitList(model: model, sections: [DateSection(title: "\(model.hits.count) 封結果", hits: model.hits)], showMatch: true)
        }
    }

    private var backRow: some View {
        Button { model.box = .inbox } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(model.box == .flagged ? "旗標" : "封存").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("回到 Inbox（Esc）")
    }

    /// Flagged mail pinned on top, showing its first rows, then the rest of the inbox by date.
    private var inboxSections: [DateSection] {
        let pinned = model.pinned.isEmpty ? [] : [DateSection(title: "旗標", hits: model.pinned, truncated: true)]
        return pinned + DateSection.group(model.rows[.inbox, default: []])
    }
}

/// A titled group of hits.
struct DateSection: Identifiable {
    let title: String
    let hits: [SearchHit]
    /// Shows its first rows and a "顯示全部" that opens the whole box.
    var truncated = false
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

/// Sectioned, keyboard-navigable list. While browsing it pages in more mail at the end; the pinned section shows
/// its first rows and "顯示全部" opens the flagged box over it.
private struct HitList: View {
    @Bindable var model: SearchModel
    let sections: [DateSection]
    let showMatch: Bool
    /// False while covered by another box: it keeps its place but takes no focus or keys.
    var active = true
    var preview = 5
    @FocusState private var focused: Bool

    private func visible(_ section: DateSection) -> [SearchHit] {
        section.truncated ? Array(section.hits.prefix(preview)) : section.hits
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
                        if section.truncated, section.hits.count > preview { showAll(section) }
                    }
                    if !showMatch { Color.clear.frame(height: 1).onAppear { model.loadMore() } }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .focusable(active)
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(characters: .init(charactersIn: "jkesu#rRf")) { press in shortcut(press, proxy) }
            .onKeyPress(.escape) {
                guard model.box != .inbox else { return .ignored }
                model.box = .inbox
                return .handled
            }
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

    private func showAll(_ section: DateSection) -> some View {
        Button { model.box = .flagged } label: {
            HStack(spacing: 4) {
                Text("顯示全部 \(Fmt.count(section.hits.count)) 封")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Gmail-style keys on the list: j/k move, e archive, # trash, s flag, u read/unread, r reply, R reply all, f forward.
    private func shortcut(_ press: KeyPress, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        switch press.characters {
        case "j": return move(1, proxy)
        case "k": return move(-1, proxy)
        default: break
        }
        guard let meta = model.message?.meta, meta.id == model.selection else { return .ignored }
        switch press.characters {
        case "e": model.perform(.archive)
        case "#": model.perform(.trash)
        case "s": model.perform(meta.isFlagged ? .unflag : .flag)
        case "u": model.perform(meta.isRead ? .markUnread : .markRead)
        case "r": model.compose(.reply)
        case "R": model.compose(.replyAll)
        case "f": model.compose(.forward)
        default: return .ignored
        }
        return .handled
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
                    Spacer(minLength: 6)
                    Text(Fmt.short(hit.meta.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 6) {
                    Text(hit.meta.subject.isEmpty ? "（無主旨）" : hit.meta.subject)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if hit.meta.isFlagged { Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(Theme.flag) }
                }
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
