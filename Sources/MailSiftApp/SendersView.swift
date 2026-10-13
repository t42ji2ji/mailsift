import MailCore
import SwiftUI

struct SendersView: View {
    @Bindable var model: SendersModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error { ErrorStrip(text: error) }
            switch model.mode {
            case .table: table
            case .map: mapArea
            }
        }
        .task {
            model.reload()
            model.loadMap()
        }
        .sheet(item: $model.plan) { TrashConfirmSheet(model: model, plan: $0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("寄件者").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
            HStack(spacing: 10) {
                ModePicker(mode: $model.mode)
                AccountPicker(accounts: model.accounts, selection: $model.account)
                Spacer()
                if let n = model.trashing {
                    ProgressView().controlSize(.mini)
                    Text("移到垃圾桶中 · \(Fmt.count(n)) 封").font(.system(size: 12)).foregroundStyle(Theme.muted)
                } else if let r = model.result {
                    Text("完成 \(Fmt.count(r.succeeded)) 封" + (r.failed > 0 ? " · 失敗 \(Fmt.count(r.failed)) 封" : ""))
                        .font(.system(size: 12, weight: r.failed > 0 ? .semibold : .regular))
                        .foregroundStyle(r.failed > 0 ? Theme.ink : Theme.muted)
                        .help(r.firstFailure ?? "")
                }
                Button {
                    model.prepareTrash()
                } label: {
                    Text(model.selection.isEmpty ? "移到垃圾桶" : "移到垃圾桶 · \(Fmt.count(model.selectedMessages)) 封")
                }
                .buttonStyle(InkButtonStyle())
                .disabled(model.selection.isEmpty || model.trashing != nil)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var mapArea: some View {
        if let map = model.map {
            SenderMapView(model: model, map: map)
                .background(Theme.canvas)
                .overlay(alignment: .bottomLeading) {
                    if !model.selection.isEmpty {
                        HStack(spacing: 10) {
                            Text("\(model.selection.count) 位寄件者 · \(Fmt.count(model.selectedMessages)) 封")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                            Button("清除選取") { model.selection = [] }.buttonStyle(LineButtonStyle())
                        }
                        .padding(10)
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 10))
                        .hairlineBorder(10)
                        .padding(16)
                    }
                }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("計算寄件者地圖").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var table: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("封數", value: \.count) { s in
                let heavy = s.count >= SendersModel.attentionCount
                Text(Fmt.count(s.count))
                    .font(.system(size: 13, weight: heavy ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(heavy ? Theme.ink : Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 68, max: 90)
            TableColumn("寄件者", value: \.address) { s in
                HStack(spacing: 6) {
                    Text(s.name.isEmpty ? s.address : s.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !s.name.isEmpty {
                        Text(s.address).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
            }
            TableColumn("帳號", value: \.account) { s in
                Text(s.account).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .width(min: 120, ideal: 190)
            TableColumn("最新", value: \.latest) { s in
                Text(Fmt.day.string(from: s.latest)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            .width(min: 80, ideal: 92, max: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 14)
    }
}

private struct ModePicker: View {
    @Binding var mode: SendersModel.Mode

    var body: some View {
        HStack(spacing: 2) {
            pill("circle.hexagongrid", "地圖", .map)
            pill("list.bullet", "列表", .table)
        }
        .padding(2)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
    }

    private func pill(_ symbol: String, _ title: String, _ value: SendersModel.Mode) -> some View {
        let on = mode == value
        return Button { mode = value } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.paper : Theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(on ? Theme.ink : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Segmented pills: 全部 + one per account.
private struct AccountPicker: View {
    let accounts: [String]
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: 2) {
            pill("全部", nil)
            ForEach(accounts, id: \.self) { pill($0, $0) }
        }
        .padding(2)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
    }

    private func pill(_ title: String, _ value: String?) -> some View {
        let on = selection == value
        return Button { selection = value } label: {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.paper : Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(on ? Theme.ink : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TrashConfirmSheet: View {
    let model: SendersModel
    let plan: SendersModel.TrashPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("移到垃圾桶").font(.system(size: 20, weight: .semibold))
                Text("\(Fmt.count(plan.total)) 封 · \(plan.lines.count) 位寄件者")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(plan.lines) { line in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.stat.name.isEmpty ? line.stat.address : line.stat.name)
                                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(line.stat.address + " · " + line.stat.account)
                                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer()
                            Text(Fmt.count(line.ids.count)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 320)
            .hairlineBorder()
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { model.plan = nil }
                    .buttonStyle(LineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("移到垃圾桶 · \(Fmt.count(plan.total)) 封") { model.confirmTrash() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(plan.total == 0)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
