// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-apple-notes",
    // SQLite3 and Compression are both in the OS; nothing is vendored and nothing is
    // fetched. macOS only — the store this reads does not exist anywhere else.
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AppleNotes", targets: ["AppleNotes"]),
    ],
    targets: [
        .target(name: "AppleNotes"),
        .testTarget(name: "AppleNotesTests", dependencies: ["AppleNotes"]),
    ]
)
