// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ArcusSignal",
    platforms: [
       .macOS(.v13)
    ],
    products: [
        .library(name: "App", targets: ["App"]),
        .executable(name: "Run", targets: ["Run"]),
        .executable(name: "RunWorker", targets: ["RunWorker"]),
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 📬 Background jobs and queue workers.
        .package(url: "https://github.com/vapor/queues.git", from: "1.17.2"),
        // 🧠 Redis queue backend.
        .package(url: "https://github.com/vapor/queues-redis-driver.git", from: "1.1.2"),
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Queues", package: "queues"),
                .product(name: "QueuesRedisDriver", package: "queues-redis-driver"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "Run",
            dependencies: ["App"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "RunWorker",
            dependencies: ["App"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
