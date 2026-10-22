import CoreServices
import Foundation

/// Calls back when Mail writes its Envelope Index or a message file lands, so new mail is picked up as it arrives
/// instead of on the next poll. Events within a second are delivered together.
public final class AppleMailWatcher: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    public init?(source: AppleMailSource, onChange: @escaping @Sendable () -> Void) {
        guard let root = try? source.storeRoot() else { return nil }
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<AppleMailWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // Mail also rewrites mailbox Info.plists, and readers (us included) touch the index's -shm.
            if paths.prefix(count).contains(where: { $0.hasSuffix(".emlx") || $0.hasSuffix("/Envelope Index")
                || $0.hasSuffix("/Envelope Index-wal") }) {
                watcher.onChange()
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "MailSift.AppleMailWatcher", qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
