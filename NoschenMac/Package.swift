// swift-tools-version: 5.9
import PackageDescription
import Foundation

// The built-in provider runs llama.cpp in-process. The llama.xcframework is
// vendored out-of-repo (see Docs/BUILTIN_MODEL.md): drop a build at
// Vendor/llama.xcframework and export NOSCHEN_LLAMA_XCFRAMEWORK with that
// relative path to enable real inference. Without it, LlamaBridge compiles a
// stub that reports the runtime as unavailable, so every target — and CI —
// builds with no binary artifact present.
let llamaXCFramework = ProcessInfo.processInfo.environment["NOSCHEN_LLAMA_XCFRAMEWORK"]

var targets: [Target] = [
    .target(
        name: "LlamaBridge",
        dependencies: llamaXCFramework != nil ? ["llama"] : [],
        path: "Sources/LlamaBridge"
    ),
    .target(
        name: "NoschenKit",
        dependencies: ["LlamaBridge"],
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
        dependencies: ["NoschenKit", "LlamaBridge"],
        path: "Tests/NoschenKitTests"
    ),
]

if let llamaXCFramework {
    targets.append(.binaryTarget(name: "llama", path: llamaXCFramework))
}

let package = Package(
    name: "Noschen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NoschenKit", targets: ["NoschenKit"]),
        .executable(name: "Noschen", targets: ["Noschen"]),
    ],
    targets: targets
)
