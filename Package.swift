// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "StockBar", platforms: [.macOS(.v13)],
    products: [.library(name: "StockBarCore", targets: ["StockBarCore"]), .executable(name: "StockBar", targets: ["StockBar"])],
    targets: [
        .target(name: "StockBarCore"),
        .executableTarget(name: "StockBar", dependencies: ["StockBarCore"]),
        .testTarget(name: "StockBarCoreTests", dependencies: ["StockBarCore"], resources: [.copy("Fixtures")])
    ]
)
