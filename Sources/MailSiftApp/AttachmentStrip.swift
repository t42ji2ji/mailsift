import AppKit
import MailCore
import SwiftUI
import UniformTypeIdentifiers

/// File attachments under the message header. Inline images that the HTML already shows are left out.
struct AttachmentStrip: View {
    let message: ParsedMessage
    let library: MailLibrary?
    @State private var error: String?
    @State private var downloading: Set<String> = []
    @State private var fetched: Set<String> = []

    private var files: [Attachment] {
        message.attachments.filter { a in
            guard a.isInline, let cid = a.contentID, let html = message.html else { return true }
            return !html.contains("cid:\(cid)")
        }
    }

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("附件 · \(files.count)")
                FlowLayout(spacing: 8) {
                    ForEach(files) { a in
                        AttachmentChip(attachment: a, downloaded: a.isDownloaded || fetched.contains(a.part), downloading: downloading.contains(a.part)) { open(a, reveal: false) }
                            .contextMenu {
                                Button("打開") { open(a, reveal: false) }
                                Button("在 Finder 中顯示") { open(a, reveal: true) }
                                Button("存到下載項目") { saveToDownloads(a) }
                            }
                            .disabled(downloading.contains(a.part))
                    }
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
        }
    }

    /// The attachment's file, having Mail download it first when it isn't on disk yet.
    private func file(_ a: Attachment) async -> URL? {
        guard let library else { return nil }
        error = nil
        if let url = try? library.attachmentFile(message.meta, a) { return url }
        downloading.insert(a.part)
        defer { downloading.remove(a.part) }
        do {
            let url = try await library.downloadAttachment(message.meta, a)
            fetched.insert(a.part)
            return url
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func open(_ a: Attachment, reveal: Bool) {
        Task {
            guard let url = await file(a) else { return }
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
        }
    }

    private func saveToDownloads(_ a: Attachment) {
        Task { await copyToDownloads(a) }
    }

    private func copyToDownloads(_ a: Attachment) async {
        guard let url = await file(a) else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var target = downloads.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = downloads.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AttachmentChip: View {
    let attachment: Attachment
    let downloaded: Bool
    let downloading: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    .overlay(alignment: .bottomTrailing) {
                        if downloading {
                            ProgressView().controlSize(.mini)
                        } else if !downloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink, Theme.paper)
                                .offset(x: 3, y: 3)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.muted)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 40)
            .frame(maxWidth: 240, alignment: .leading)
            .background(hovering ? Theme.hover : Theme.fill, in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(downloaded ? attachment.filename : "點一下從伺服器下載並打開")
    }

    private var icon: NSImage {
        let ext = (attachment.filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? UTType(mimeType: attachment.mimeType) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    private var detail: String {
        let size = attachment.size.map { Fmt.bytes(Int64($0)) }
        if downloading { return "下載中…" }
        return downloaded ? (size ?? attachment.mimeType) : "未下載" + (size.map { " · \($0)" } ?? "")
    }
}

/// Left-to-right wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
