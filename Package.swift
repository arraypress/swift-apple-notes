// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-apple-notes",
    // SQLite is read through swift-sqlite-reader; SQLite3 and Compression are both in the
    // OS, and nothing is vendored. macOS only — the store this reads does not exist anywhere else.
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AppleNotes", targets: ["AppleNotes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/arraypress/swift-sqlite-reader.git", from: "0.2.0"),
    ],
    targets: [
        .target(name: "AppleNotes", dependencies: [
            .product(name: "SQLiteReader", package: "swift-sqlite-reader"),
        ]),
        .testTarget(name: "AppleNotesTests", dependencies: ["AppleNotes"]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
