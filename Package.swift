// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CryptoTickerBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CryptoTickerBar", targets: ["CryptoTickerBar"])
    ],
    targets: [
        .executableTarget(
            name: "CryptoTickerBar",
            path: "Sources/CryptoTickerBar"
        )
    ]
)
