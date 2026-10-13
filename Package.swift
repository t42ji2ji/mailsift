// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailSift",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "EmbedKit", exclude: ["LICENSE-FluidUse", "NOTICE.md"]),
        .target(name: "MailCore", dependencies: ["EmbedKit"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "mailsift", dependencies: ["MailCore"]),
        .executableTarget(name: "MailSiftApp", dependencies: ["MailCore"]),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
    ],
    swiftLanguageModes: [.v5]
)
