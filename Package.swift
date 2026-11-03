// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DNSPulse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DNSPulse",
            path: "Sources/DNSPulse",
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)
