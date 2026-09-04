// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UnZip",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "UnZip", targets: ["UnZip"])
    ],
    targets: [
        .executableTarget(
            name: "UnZip",
            path: "Sources/UnZip"
        )
    ]
)
