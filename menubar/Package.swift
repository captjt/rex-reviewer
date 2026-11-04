// swift-tools-version: 6.0
// Rex Reviewer: the menu bar app for rex-reviewer. ./build.sh builds it into
// ~/Applications.
import PackageDescription

let package = Package(
    name: "RexReviewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RexReviewer", path: "Sources/RexReviewer"),
    ]
)
