// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AAI2Lama",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AAI2Lama",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/AAI2Lama"
        ),
    ]
)
