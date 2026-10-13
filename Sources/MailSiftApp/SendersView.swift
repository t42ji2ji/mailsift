import MailCore
import SwiftUI

struct SendersView: View {
    @Bindable var model: SendersModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("帳號", selection: $model.account) {
                    Text("全部").tag(String?.none)
                    ForEach(model.accounts, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .frame(maxWidth: 320)
                Spacer()
                if let n = model.trashing {
                    ProgressView().controlSize(.small)
                    Text("移到垃圾桶中 \(Fmt.count(n)) 封").font(.callout)
                } else if let r = model.result {
                    Text("完成 \(Fmt.count(r.succeeded)) 封 · 失敗 \(Fmt.count(r.failed)) 封")
                        .font(.callout)
                        .foregroundStyle(r.failed > 0 ? .orange : .secondary)
                        .help(r.firstFailure ?? "")
                }
                Button("移到垃圾桶…") { model.prepareTrash() }
                    .disabled(model.selection.isEmpty || model.trashing != nil)
            }
            .padding(8)
            if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.bottom, 6)
            }
            Divider()
            table
        }
        .task { model.reload() }
        .sheet(item: $model.plan) { TrashConfirmSheet(model: model, plan: $0) }
    }

    private var table: some View {
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("封數", value: \.count) { s in
                Text(Fmt.count(s.count))
                    .monospacedDigit()
                    .fontWeight(s.count >= SendersModel.attentionCount ? .bold : .regular)
                    .foregroundStyle(s.count >= SendersModel.attentionCount ? Color.orange : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 64, max: 90)
            TableColumn("最新", value: \.latest) { s in
                Text(Fmt.day.string(from: s.latest)).monospacedDigit()
            }
            .width(min: 80, ideal: 92, max: 120)
            TableColumn("帳號", value: \.account) { s in Text(s.account).lineLimit(1) }
                .width(min: 120, ideal: 200)
            TableColumn("寄件者", value: \.address) { s in
                Text(s.name.isEmpty ? s.address : "\(s.name) <\(s.address)>").lineLimit(1)
            }
        }
    }
}

private struct TrashConfirmSheet: View {
    let model: SendersModel
    let plan: SendersModel.TrashPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("將 \(Fmt.count(plan.total)) 封郵件移到垃圾桶？").font(.headline)
            List(plan.lines) { line in
                HStack {
                    Text(line.stat.name.isEmpty ? line.stat.address : "\(line.stat.name) <\(line.stat.address)>")
                        .lineLimit(1)
                    Spacer()
                    Text(line.stat.account).foregroundStyle(.secondary).lineLimit(1)
                    Text(Fmt.count(line.ids.count)).monospacedDigit().frame(minWidth: 50, alignment: .trailing)
                }
            }
            .frame(minHeight: 160, maxHeight: 360)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.plan = nil }
                    .keyboardShortcut(.cancelAction)
                Button("移到垃圾桶", role: .destructive) { model.confirmTrash() }
                    .disabled(plan.total == 0)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
