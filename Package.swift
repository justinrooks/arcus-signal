// swift-tools-version:6.3
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
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.3"),
        // 🗄️ ORM + PostgreSQL driver.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        // 📬 Background jobs and queue workers.
        .package(url: "https://github.com/vapor/queues.git", from: "1.18.0"),
        // 🧠 Redis queue backend.
        .package(url: "https://github.com/vapor/queues-redis-driver.git", from: "1.1.2"),
        // ⬡ H3 Geospacial Encoding
        .package(url: "https://github.com/pawelmajcher/SwiftyH3.git", from: "0.5.0"),
        // 📩 APNs push notifications
        .package(url: "https://github.com/vapor/apns.git", from: "5.0.0"),
        // ArcusCore
        .package(url: "https://github.com/justinrooks/ArcusCore.git", from: "0.1.0"),
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
                .product(name: "SwiftyH3", package: "SwiftyH3"),
                .product(name: "VaporAPNS", package: "apns"),
                .product(name: "ArcusCore", package: "ArcusCore"),
            ],
            path: "Sources/App",
            sources: [
                "Clients",
                "Controllers",
                "Extensions",
                "Jobs",
                "Migrations",
                "Models",
                "Infrastructure/Hashing",
                "Infrastructure/Networking",
                "Infrastructure/Notifications",
                "Infrastructure/PressureArtifactBlockingWorkExecutor.swift",
                "Infrastructure/Cancellation.swift",
                "Services",
                "StormSetup",
                "Worker",
                "lib",
                "apiRoutes.swift",
                "configure.swift"
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "Run",
            dependencies: ["App"],
            path: "Sources/Run",
            sources: ["main.swift"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "RunWorker",
            dependencies: ["App"],
            path: "Sources/RunWorker",
            sources: ["main.swift"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "XCTQueues", package: "queues"),
            ],
            path: "Tests/AppTests",
            exclude: [
                "Fixtures"
            ],
            sources: ["."],
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
