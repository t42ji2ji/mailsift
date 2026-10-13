import AppKit
import SwiftUI

/// NSSearchField that reports text only when no IME composition is in progress (Zhuyin, Pinyin…):
/// a 250 ms debounce after the last committed change, or immediately on Enter.
struct IMESearchField: NSViewRepresentable {
    var prompt: String
    var onCommit: (String) -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.enter(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.onCommit = onCommit
        field.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        static let debounce: Duration = .milliseconds(250)

        var onCommit: (String) -> Void
        private var pending: Task<Void, Never>?

        init(onCommit: @escaping (String) -> Void) { self.onCommit = onCommit }

        private func isComposing(_ field: NSTextField) -> Bool {
            (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            pending?.cancel()
            guard !isComposing(field) else { return }
            let text = field.stringValue
            pending = Task { [weak self] in
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled, let self, !self.isComposing(field) else { return }
                self.onCommit(text)
            }
        }

        @objc func enter(_ sender: NSSearchField) {
            guard !isComposing(sender) else { return }
            pending?.cancel()
            onCommit(sender.stringValue)
        }
    }
}
