import Foundation
import MailCore

/// A grouping for unread mail, usually set up by the assistant: matching messages fold into one row under its name,
/// across senders (all of a bank's login notices, every newsletter).
struct FoldRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Sender address or domain fragments; any one matches. Empty: any sender.
    var senders: [String]
    /// Subject fragments; any one matches. Empty: any subject.
    var subjects: [String]

    func matches(_ m: MessageMeta) -> Bool {
        guard !senders.isEmpty || !subjects.isEmpty else { return false }
        let address = m.senderAddress.lowercased()
        return (senders.isEmpty || senders.contains { address.contains($0.lowercased()) })
            && (subjects.isEmpty || subjects.contains { m.subject.localizedCaseInsensitiveContains($0) })
    }

    /// One line for settings and the agent's context: who and what it matches.
    var summary: String {
        [senders.isEmpty ? nil : "寄件者含 " + senders.joined(separator: "、"),
         subjects.isEmpty ? nil : "主旨含 " + subjects.joined(separator: "、")]
            .compactMap { $0 }.joined(separator: "，")
    }

    static let key = "foldRules"

    static func load() -> [FoldRule] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([FoldRule].self, from: $0) } ?? []
    }

    static func save(_ rules: [FoldRule]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: key)
    }
}
