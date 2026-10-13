import Foundation
import MailCore

enum Fmt {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func count(_ n: Int) -> String { n.formatted(.number) }

    /// List dates: 14:20 today, 10/08 this year, 2022/06/30 otherwise.
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(d) {
            return "昨天"
        } else if cal.component(.year, from: d) == cal.component(.year, from: .now) {
            f.dateFormat = "M/d"
        } else {
            f.dateFormat = "yyyy/M/d"
        }
        return f.string(from: d)
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func sender(_ m: MessageMeta) -> String { m.senderName.isEmpty ? m.senderAddress : m.senderName }

    static func phase(_ p: IndexStatus.Phase) -> String {
        switch p {
        case .idle: "閒置"
        case .syncing: "同步中"
        case .embedding: "建立語意索引中"
        case .done: "完成"
        case .failed: "失敗"
        }
    }

    static func model(_ m: AppModel.ModelState) -> String {
        switch m {
        case .notLoaded: "未載入"
        case .loading(let file, let bytes):
            file.isEmpty ? "載入中" : "載入中 \(file) \(bytes > 0 ? Fmt.bytes(bytes) : "")"
        case .loaded: "已載入"
        case .failed(let e): "載入失敗：\(e)"
        }
    }
}
