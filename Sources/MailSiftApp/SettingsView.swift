import MailCore
import SwiftUI

struct SettingsView: View {
    static let loadRemoteKey = "loadRemoteContent"
    let search: SearchModel
    @AppStorage(loadRemoteKey) private var loadRemote = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("設定").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("郵件內容")
                    Toggle(isOn: $loadRemote) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自動載入遠端內容").font(.system(size: 13, weight: .medium))
                            Text("郵件裡的圖片、樣式和字型直接從寄件方的伺服器載入，對方會看到你的 IP 和讀信時間。關閉後，每封信可以用工具列的圖片按鈕個別載入。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                }
                CategorySettings(search: search)
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("帳號")
                    Text("MailSift 讀的是 Apple Mail 裡的帳號。在系統設定的「網際網路帳號」加入帳號並開啟「郵件」，下一次同步就會出現。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("新增郵件帳號…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                    }
                    .buttonStyle(LineButtonStyle())
                }
            }
            .overlayScroller()
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Order (drag), visibility and custom categories for the chips over the list.
private struct CategorySettings: View {
    let search: SearchModel
    @State private var items: [MailCategory] = []
    /// The custom category in the form: an existing id, or nil for a new one.
    @State private var editing: String?
    @State private var formOpen = false
    @State private var name = ""
    @State private var detail = ""
    private static let rowHeight: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("分類")
            Text("拖曳調整順序。隱藏只是不顯示標籤；新增或修改描述後，所有信會重新分類一次。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(items) { row($0) }
                    .onMove { from, to in
                        items.move(fromOffsets: from, toOffset: to)
                        search.saveCategories(items)
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(items.count) * Self.rowHeight)
            .hairlineBorder()
            if formOpen { form } else {
                Button("新增分類") { open(nil) }.buttonStyle(LineButtonStyle())
            }
        }
        .onAppear { items = search.library?.categories() ?? search.categories }
    }

    private func row(_ c: MailCategory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text(c.name).font(.system(size: 13, weight: .medium)).foregroundStyle(c.hidden ? Theme.faint : Theme.ink)
            if !c.isBuiltIn {
                Text(c.description).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !c.isBuiltIn {
                IconButton(symbol: "pencil", help: "編輯") { open(c) }
                IconButton(symbol: "trash", help: "刪除") { update { $0.removeAll { $0.id == c.id } } }
            }
            IconButton(symbol: c.hidden ? "eye.slash" : "eye", help: c.hidden ? "顯示標籤" : "隱藏標籤") {
                update { list in
                    if let i = list.firstIndex(where: { $0.id == c.id }) { list[i].hidden.toggle() }
                }
            }
        }
        .frame(height: Self.rowHeight)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("名稱") {
                TextField("", text: $name, prompt: Text("例如：學校"))
            }
            field("描述") {
                TextField("", text: $detail, prompt: Text("例如：學校課程、作業繳交、期中考、教授與助教公告、選課 course, assignment, exam"), axis: .vertical)
                    .lineLimit(3...6)
            }
            Text("寫這類信裡真的會出現的字：常見主旨、寄件單位、服務名稱，中英文都放。具體的詞比多更重要，別寫到其他分類也會出現的字，例如「通知」「更新」。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(editing == nil ? "新增" : "儲存") { save() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || detail.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("取消") { formOpen = false }.buttonStyle(LineButtonStyle())
            }
        }
        .padding(16)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
    }

    private func field(_ label: String, @ViewBuilder _ input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            input()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.radius))
                .hairlineBorder()
        }
    }

    private func open(_ c: MailCategory?) {
        editing = c?.id
        name = c?.name ?? ""
        detail = c?.description ?? ""
        formOpen = true
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        update { list in
            if let id = editing, let i = list.firstIndex(where: { $0.id == id }) {
                list[i].name = name
                list[i].description = detail
            } else {
                list.append(MailCategory(name: name, description: detail))
            }
        }
        formOpen = false
    }

    private func update(_ change: (inout [MailCategory]) -> Void) {
        change(&items)
        search.saveCategories(items)
    }
}
