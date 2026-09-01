// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MeetNotes",
            path: "Sources/MeetNotes",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
