// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeTimeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodeTimeCore", targets: ["CodeTimeCore"]),
        .library(name: "SharedModels", targets: ["SharedModels"]),
        .library(name: "BackupEngine", targets: ["BackupEngine"]),
        .library(name: "CloudMirrorStore", targets: ["CloudMirrorStore"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "CodeTimeSecurity", targets: ["CodeTimeSecurity"]),
        .library(name: "GitIntegration", targets: ["GitIntegration"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "SharedModels"),
        .target(name: "Persistence", dependencies: ["SharedModels", "CSQLite"]),
        .target(name: "CodeTimeSecurity", dependencies: ["SharedModels"], path: "Sources/Security"),
        .target(
            name: "BackupEngine",
            dependencies: ["SharedModels"],
            resources: [.copy("Resources/ExclusionPresets")]
        ),
        .target(name: "CloudMirrorStore", dependencies: ["SharedModels", "CodeTimeSecurity"]),
        .target(name: "GitIntegration", dependencies: ["SharedModels"]),
        .target(name: "Diagnostics", dependencies: ["SharedModels"]),
        .target(
            name: "CodeTimeCore",
            dependencies: [
                "SharedModels", "Persistence", "CodeTimeSecurity", "BackupEngine",
                "CloudMirrorStore", "GitIntegration", "Diagnostics",
            ]
        ),
        .testTarget(
            name: "CodeTimeKitTests",
            dependencies: ["CodeTimeCore", "SharedModels", "Persistence", "CodeTimeSecurity", "BackupEngine", "CloudMirrorStore", "CSQLite"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
