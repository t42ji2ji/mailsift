import AppKit
import MailCore
import SwiftUI

struct StatusView: View {
    let app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("索引與連接").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                index
                connect
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 44)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var index: some View {
        let s = app.status
        let total = max(s.totalMessages, 1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("索引")
                Spacer()
                Button("重新同步") { app.resync() }.buttonStyle(LineButtonStyle())
            }
            HStack(spacing: 12) {
                Stat(label: "郵件", value: Fmt.count(s.totalMessages), progress: nil)
                Stat(label: "關鍵字", value: Fmt.count(s.keywordIndexed), progress: Double(s.keywordIndexed) / Double(total))
                Stat(label: "語意", value: Fmt.count(s.vectorIndexed), progress: Double(s.vectorIndexed) / Double(total))
            }
            VStack(spacing: 0) {
                Line(label: "狀態", value: Fmt.phase(s.phase) + (s.message.map { " · \($0)" } ?? ""))
                Line(label: "模型", value: Fmt.model(app.model))
                Line(label: "資料庫", value: app.databaseURL.path, mono: true, last: true)
            }
            .hairlineBorder()
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("連接 AGENT · MCP")
            CommandBlock(label: "Claude Code", command: "claude mcp add mailsift -- \(CLIPath.quoted) mcp")
            CommandBlock(label: "Codex", command: "codex mcp add mailsift -- \(CLIPath.quoted) mcp")
            CommandBlock(label: "CLI", command: CLIPath.url.path)
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 24, weight: .semibold).monospacedDigit()).tracking(-0.5)
            if let progress { ThinProgress(value: progress) } else { Color.clear.frame(height: 3) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Line: View {
    let label: String
    let value: String
    var mono = false
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                Text(value)
                    .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if !last { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
    }
}

private struct CommandBlock: View {
    let label: String
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium))
            HStack(alignment: .top, spacing: 10) {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "拷貝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.radius))
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
