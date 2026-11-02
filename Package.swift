// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FrameRec",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FrameRec", targets: ["FrameRec"])],
    targets: [
        .target(name: "FrameRecCore"),
        .target(name: "FrameRecUI", dependencies: ["FrameRecCore"]),
        .executableTarget(name: "FrameRec", dependencies: ["FrameRecCore", "FrameRecUI"]),
        .executableTarget(name: "FrameRecSelectionProbe", dependencies: ["FrameRecUI", "FrameRecCore"], path: "Tools/SelectionProbe"),
        .testTarget(name: "FrameRecCoreTests", dependencies: ["FrameRecCore"]),
        .testTarget(name: "FrameRecUITests", dependencies: ["FrameRecUI"]),
    ],
    swiftLanguageModes: [.v5]
)
