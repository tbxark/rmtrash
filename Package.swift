// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "rmtrash",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(name: "rmtrash", targets: ["rmtrash"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0")
    ],
    targets: [
        .executableTarget(
            name: "rmtrash",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "rmtrashTests",
            dependencies: ["rmtrash"]
        )
    ]
)
