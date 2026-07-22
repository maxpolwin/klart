// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Klart",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KlartKit", targets: ["KlartKit"]),
        .executable(name: "Klart", targets: ["Klart"]),
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
            name: "KlartKit",
            dependencies: ["CArgon2"],
            path: "Sources/KlartKit"
        ),
        .executableTarget(
            name: "Klart",
            dependencies: ["KlartKit"],
            path: "Sources/KlartApp",
            exclude: ["Resources/Info.plist"],
            // Embed an Info.plist into the bare executable so `swift run`
            // gets App Transport Security exceptions for localhost providers
            // (Ollama / LM Studio) even outside a .app bundle.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/KlartApp/Resources/Info.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "KlartKitTests",
            dependencies: ["KlartKit"],
            path: "Tests/KlartKitTests"
        ),
    ]
)
