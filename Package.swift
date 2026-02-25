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
        // 🗄️ ORM + PostgreSQL driver.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.10.0"),
        // 📬 Background jobs and queue workers.
        .package(url: "https://github.com/vapor/queues.git", from: "1.17.2"),
        // 🧠 Redis queue backend.
        .package(url: "https://github.com/vapor/queues-redis-driver.git", from: "1.1.2"),
        // ⬡ H3 Geospacial Encoding
        .package(url: "https://github.com/pawelmajcher/SwiftyH3.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Queues", package: "queues"),
                .product(name: "QueuesRedisDriver", package: "queues-redis-driver"),
                .product(name: "SwiftyH3", package: "SwiftyH3")
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
                .product(name: "XCTQueues", package: "queues"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
