// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Noschen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NoschenKit", targets: ["NoschenKit"]),
        .executable(name: "Noschen", targets: ["Noschen"]),
    ],
    targets: [
        // Vendored, hash-pinned PHC reference Argon2 (see Sources/CArgon2/
        // THIRD_PARTY.md). Compiled in-tree; nothing is fetched at build time.
        .target(
            name: "CArgon2",
            path: "Sources/CArgon2",
            exclude: ["LICENSE", "THIRD_PARTY.md"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
            ]
        ),
        .target(
            name: "NoschenKit",
            dependencies: ["CArgon2"],
            path: "Sources/NoschenKit"
        ),
        .executableTarget(
            name: "Noschen",
            dependencies: ["NoschenKit"],
            path: "Sources/NoschenApp",
            exclude: ["Resources/Info.plist"],
            // Embed an Info.plist into the bare executable so `swift run`
            // gets App Transport Security exceptions for localhost providers
            // (Ollama / LM Studio) even outside a .app bundle.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/NoschenApp/Resources/Info.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "NoschenKitTests",
            dependencies: ["NoschenKit"],
            path: "Tests/NoschenKitTests"
        ),
    ]
)
