// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FinanceDashboard",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FinanceCore", targets: ["FinanceCore"])],
    targets: [
        .target(name: "FinanceCore"),
        .testTarget(name: "FinanceCoreTests", dependencies: ["FinanceCore"]),
    ]
)
