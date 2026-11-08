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
                "SharedModels", "Persistence", "CSQLite", "CodeTimeSecurity", "BackupEngine",
                "CloudMirrorStore", "GitIntegration", "Diagnostics",
            ]
        ),
        // CT-098: standalone child process used by regression tests to exercise
        // real SIGKILL crash recovery (migration phases, lifecycle locks). It is
        // a test harness, not a product.
        .executableTarget(
            name: "CodeTimeCrashChild",
            dependencies: ["CodeTimeCore", "SharedModels", "BackupEngine", "CodeTimeSecurity"]
        ),
        .testTarget(
            name: "CodeTimeKitTests",
            dependencies: ["CodeTimeCore", "SharedModels", "Persistence", "CodeTimeSecurity", "BackupEngine", "CloudMirrorStore", "CSQLite"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
