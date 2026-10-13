import EmbedKit
import Foundation

/// EmbeddingGemma 2 on Core ML (Neural Engine). Documents get `title: … | text: …`, queries the search-result prefix.
public final class CoreMLEmbedder: TextEmbedder {
    public static let maxTokens = 512
    private let manager: EmbeddingGemma2Manager

    public var dimension: Int { EmbeddingGemma2Manager.dimension }

    init(manager: EmbeddingGemma2Manager) { self.manager = manager }

    /// Uses `EMBEDDINGGEMMA2_MODEL_DIR` when set; otherwise downloads (once, ~570 MB) into
    /// ~/Library/Application Support/MailSift/Models. The first load compiles for the Neural Engine (~2 min, cached).
    public static func load(
        progress: (@Sendable (_ file: String, _ bytes: Int64) -> Void)? = nil
    ) async throws -> CoreMLEmbedder {
        CoreMLEmbedder(manager: try await EmbeddingGemma2Manager.loadDefault(progress: progress))
    }

    public func embedDocuments(_ docs: [(title: String, body: String)]) async throws -> [[Float]] {
        // The manager takes one prompt per batch, so the per-document title prefix is applied here.
        let texts = docs.map {
            EmbeddingGemma2Prompt.document(title: $0.title.isEmpty ? nil : $0.title).apply(to: $0.body)
        }
        return try await manager.embed(texts, prompt: .none, maxTokens: Self.maxTokens)
    }

    public func embedQuery(_ query: String) async throws -> [Float] {
        try await manager.embed(query, prompt: .searchQuery)
    }
}
