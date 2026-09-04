// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BiliFetch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BiliFetch", targets: ["BiliFetch"])
    ],
    targets: [
        .executableTarget(
            name: "BiliFetch",
            path: "Sources/BiliFetch"
        )
    ],
    swiftLanguageVersions: [.v5]
)
