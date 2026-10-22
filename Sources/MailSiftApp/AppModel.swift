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
    /// Bumped after every index run, so lists can reload.
    private(set) var indexRevision = 0
    @ObservationIgnored private var indexing = false
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: AppleMailWatcher?
    /// Mail changed while an index run was going; run again when it ends.
    @ObservationIgnored private var changedWhileIndexing = false
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
            SearchService.serve(lib)
            status = lib.status()
            readiness = .ready
            loadModel()
            runIndex(lib)
            startAutoSync(lib)
            watcher = AppleMailWatcher(source: source) {
                Task { @MainActor in self.mailChanged(lib) }
            }
        } catch {
            readiness = .failed(error.localizedDescription)
        }
    }

    /// Polled while the access screen is up, so granting access in System Settings continues without a relaunch.
    func recheckAccess() {
        guard case .needsFullDiskAccess = readiness, (try? AppleMailSource().checkAccess()) != nil else { return }
        start()
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// Cancels the running sync/embedding and starts over (both resume where they stopped).
    func resync() {
        guard let lib = library else { return }
        runIndex(lib, force: true)
    }

    /// Has Mail fetch from the servers now, then resyncs; looks again shortly after for mail still downloading.
    func refreshNow() {
        guard let lib = library else { return }
        Self.wakeMail()
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Mail\" to check for new mail")?.executeAndReturnError(&error)
        }
        runIndex(lib, force: true)
        Task {
            try? await Task.sleep(for: .seconds(8))
            if !indexing { runIndex(lib) }
        }
    }

    private func mailChanged(_ lib: MailLibrary) {
        if indexing { changedWhileIndexing = true } else { runIndex(lib) }
    }

    /// New mail arrives through Mail.app; the watcher picks it up as it lands, this every minute in case it misses
    /// (sync only reads what changed).
    private func startAutoSync(_ lib: MailLibrary) {
        autoSyncTask?.cancel()
        autoSyncTask = Task {
            while !Task.isCancelled {
                Self.wakeMail()
                try? await Task.sleep(for: .seconds(60))
                if !indexing { runIndex(lib) }
            }
        }
    }

    /// Only Mail fetches mail and posts its notifications: keep it running, hidden and in the background.
    private static func wakeMail() {
        let id = "com.apple.mail"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
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
    private func runIndex(_ lib: MailLibrary, force: Bool = false) {
        let previous = indexTask
        previous?.cancel()
        let report: MailLibrary.Progress = { s in
            Task { @MainActor in self.status = s }
        }
        // Below the user's own actions: opening mail and marking it read come first.
        indexTask = Task(priority: .utility) {
            await previous?.value
            indexing = true
            // Nothing changed in Mail: the lists stay as they are.
            var changed = true
            defer {
                indexing = false
                if changed { indexRevision += 1 }
                if changedWhileIndexing {
                    changedWhileIndexing = false
                    Task { runIndex(lib) }
                }
            }
            do {
                changed = try await lib.sync(force: force, progress: report)
                guard changed else { return }
                // New mail is listable now; don't hold the lists until embedding finishes.
                indexRevision += 1
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
