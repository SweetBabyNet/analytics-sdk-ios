// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Analytics",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "Analytics", targets: ["Analytics"])
    ],
    targets: [
        .target(name: "Analytics", dependencies: [])
    ]
)
