import SwiftUI

struct SettingsView: View {
    static let loadRemoteKey = "loadRemoteContent"
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
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
