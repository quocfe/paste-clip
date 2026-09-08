// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipStack",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ClipStackCore", targets: ["ClipStackCore"]),
               .executable(name: "ClipStack", targets: ["ClipStack"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0")],
    targets: [
        .target(name: "ClipStackCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "ClipStack", dependencies: ["ClipStackCore"]),
        .testTarget(name: "ClipStackCoreTests", dependencies: ["ClipStackCore"]),
        .testTarget(name: "ClipStackUITests", dependencies: ["ClipStack"])
    ],
    swiftLanguageModes: [.v5]
)
