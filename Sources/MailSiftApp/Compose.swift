import AppKit

/// New mail is written in Mail.app itself (it owns the accounts and sending).
enum Compose {
    static func newMessage() {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: """
                tell application "Mail"
                    make new outgoing message with properties {visible:true}
                    activate
                end tell
                """)?.executeAndReturnError(&error)
        }
    }
}
