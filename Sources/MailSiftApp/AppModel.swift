import AppKit
import Foundation
import MailCore
import Observation

/// App-wide state: access check, library, background sync + model load + embedding. Views only read this.
@MainActor @Observable
final class AppModel {
    enum Readiness {
        case checking
        case needsFullDiskAccess
        case failed(String)
        case ready
    }

    enum ModelState {
        case notLoaded
        case loading(file: String, bytes: Int64)
        case loaded
        case failed(String)
    }

    private(set) var readiness: Readiness = .checking
    private(set) var model: ModelState = .notLoaded
    private(set) var status = IndexStatus(phase: .idle, totalMessages: 0, keywordIndexed: 0, vectorIndexed: 0)
    private(set) var library: MailLibrary?

    let databaseURL = MailLibrary.defaultDatabaseURL()
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var modelTask: Task<CoreMLEmbedder?, Never>?

    func start() {
        guard library == nil else { return }
        readiness = .checking
        let source = AppleMailSource()
        do {
            try source.checkAccess()
        } catch MailSourceError.fullDiskAccessRequired {
            readiness = .needsFullDiskAccess
            return
        } catch {
            readiness = .failed(error.localizedDescription)
            return
        }
        do {
            let lib = try MailLibrary(source: source, embedder: nil, databaseURL: databaseURL)
            library = lib
            status = lib.status()
            readiness = .ready
            loadModel()
            runIndex(lib)
        } catch {
            readiness = .failed(error.localizedDescription)
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// Cancels the running sync/embedding and starts over (both resume where they stopped).
    func resync() {
        guard let lib = library else { return }
        runIndex(lib)
    }

    /// Called after actions that change the index outside sync (trash).
    func refreshStatus() {
        if let library { status = library.status() }
    }

    private func loadModel() {
        model = .loading(file: "", bytes: 0)
        // The download callback fires per chunk; publish only on a new file or every ~1 MB.
        let throttle = ProgressThrottle()
        modelTask = Task {
            do {
                let embedder = try await CoreMLEmbedder.load { file, bytes in
                    guard throttle.shouldReport(file: file, bytes: bytes) else { return }
                    Task { @MainActor in
                        if case .loading = self.model { self.model = .loading(file: file, bytes: bytes) }
                    }
                }
                model = .loaded
                return embedder
            } catch {
                model = .failed(error.localizedDescription)
                return nil
            }
        }
    }

    /// Sync first (keyword search), then embed once both sync and the model are done.
    /// `MailLibrary` refuses overlapping index runs, so the previous run is cancelled and awaited first.
    private func runIndex(_ lib: MailLibrary) {
        let previous = indexTask
        previous?.cancel()
        let report: MailLibrary.Progress = { s in
            Task { @MainActor in self.status = s }
        }
        indexTask = Task {
            await previous?.value
            do {
                try await lib.sync(progress: report)
                // Polled rather than awaited so that a resync during the model download can cancel this run.
                while case .loading = model { try await Task.sleep(for: .milliseconds(250)) }
                guard case .loaded = model, let embedder = await modelTask?.value else { return }
                lib.setEmbedder(embedder)
                try await lib.embedPending(progress: report)
            } catch {
                // Status already carries the failure or cancellation.
            }
            status = lib.status()
        }
    }
}

private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var file = ""
    private var bytes: Int64 = 0

    func shouldReport(file: String, bytes: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard file != self.file || bytes - self.bytes >= 1 << 20 || bytes < self.bytes else { return false }
        self.file = file
        self.bytes = bytes
        return true
    }
}
