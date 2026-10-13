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

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func sender(_ m: MessageMeta) -> String { m.senderName.isEmpty ? m.senderAddress : m.senderName }

    /// 關鍵字 37,628/37,628 · 語意 12,400/37,628
    static func indexLine(_ s: IndexStatus) -> String {
        "關鍵字 \(count(s.keywordIndexed))/\(count(s.totalMessages)) · 語意 \(count(s.vectorIndexed))/\(count(s.totalMessages))"
    }

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
