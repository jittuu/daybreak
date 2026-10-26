// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Daybreak",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "daybreak-helper", targets: ["DaybreakHelper"])],
    targets: [
        .target(name: "DaybreakCore"),
        .executableTarget(name: "DaybreakHelper", dependencies: ["DaybreakCore"]),
        .testTarget(name: "DaybreakCoreTests", dependencies: ["DaybreakCore"])
    ]
)
