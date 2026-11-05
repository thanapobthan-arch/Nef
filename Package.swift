// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "NefCopy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NefCopy", targets: ["NefCopy"])],
    targets: [
        .target(name: "CXXHash", path: "Sources/CXXHash", publicHeadersPath: "include"),
        .executableTarget(name: "NefCopy", dependencies: ["CXXHash"], path: "Sources/NefCopy"),
        .testTarget(name: "NefCopyTests", dependencies: ["NefCopy"], path: "Tests/NefCopyTests")
    ]
)
