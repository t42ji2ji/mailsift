import AppKit
import MailCore
import SwiftUI

struct StatusView: View {
    let app: AppModel

    var body: some View {
        Form {
            Section("索引") {
                LabeledContent("狀態", value: Fmt.phase(app.status.phase))
                LabeledContent("郵件", value: Fmt.count(app.status.totalMessages))
                LabeledContent("關鍵字索引", value: Fmt.count(app.status.keywordIndexed))
                LabeledContent("語意索引", value: Fmt.count(app.status.vectorIndexed))
                if let note = app.status.message { LabeledContent("訊息", value: note) }
                LabeledContent("模型", value: Fmt.model(app.model))
                LabeledContent("資料庫") {
                    Text(app.databaseURL.path).textSelection(.enabled).font(.callout.monospaced())
                }
                Button("重新同步") { app.resync() }
            }
            Section("連接 Agent（MCP）") {
                CommandRow(label: "Claude Code", command: "claude mcp add mailsift -- \(CLIPath.quoted) mcp")
                CommandRow(label: "Codex", command: "codex mcp add mailsift -- \(CLIPath.quoted) mcp")
                LabeledContent("CLI") {
                    Text(CLIPath.url.path).textSelection(.enabled).font(.callout.monospaced())
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CommandRow: View {
    let label: String
    let command: String

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(command).textSelection(.enabled).font(.callout.monospaced()).lineLimit(2)
                Button("拷貝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
        }
    }
}

enum CLIPath {
    /// The CLI shipped in Contents/Helpers; when running unbundled, the build directory's.
    static let url: URL = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mailsift")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("mailsift")
    }()

    static var quoted: String { "\"\(url.path)\"" }
}
