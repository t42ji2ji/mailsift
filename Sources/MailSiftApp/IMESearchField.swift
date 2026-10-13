import AppKit
import SwiftUI

/// Borderless text field that reports text only when no IME composition is in progress (Zhuyin, Pinyin…):
/// a 250 ms debounce after the last committed change, or immediately on Enter.
struct IMESearchField: NSViewRepresentable {
    var prompt: String
    /// Changing this value clears the field (and commits the empty string).
    var clearToken = 0
    var onEdit: (Bool) -> Void = { _ in }
    var onCommit: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = prompt
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.enter(_:))
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onEdit = onEdit
        field.placeholderString = prompt
        if context.coordinator.clearToken != clearToken {
            context.coordinator.clearToken = clearToken
            field.stringValue = ""
            let (onEdit, onCommit) = (onEdit, onCommit)
            DispatchQueue.main.async {  // not during the SwiftUI update pass
                onEdit(false)
                onCommit("")
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(onCommit: onCommit)
        c.clearToken = clearToken
        return c
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        static let debounce: Duration = .milliseconds(250)

        var onCommit: (String) -> Void
        var onEdit: (Bool) -> Void = { _ in }
        var clearToken = 0
        private var pending: Task<Void, Never>?

        init(onCommit: @escaping (String) -> Void) { self.onCommit = onCommit }

        private func isComposing(_ field: NSTextField) -> Bool {
            (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            onEdit(!field.stringValue.isEmpty)
            pending?.cancel()
            guard !isComposing(field) else { return }
            let text = field.stringValue
            pending = Task { [weak self] in
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled, let self, !self.isComposing(field) else { return }
                self.onCommit(text)
            }
        }

        @objc func enter(_ sender: NSTextField) {
            guard !isComposing(sender) else { return }
            pending?.cancel()
            onCommit(sender.stringValue)
        }
    }
}
