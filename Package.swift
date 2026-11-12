// swift-tools-version:6.3.3
import PackageDescription

let package = Package(
  name: "IMGLYPluginVoiceIsolation",
  defaultLocalization: "en",
  platforms: [.iOS(.v16)],
  products: [
    .library(
      name: "IMGLYPluginVoiceIsolationCore",
      targets: ["IMGLYPluginVoiceIsolationCore"],
    ),
    .library(
      name: "IMGLYPluginVoiceIsolationONNX",
      targets: ["IMGLYPluginVoiceIsolationONNX"],
    ),
    // Umbrella: importing `IMGLYPluginVoiceIsolation` re-exports Core and ONNX, and unlocks the initializers without a
    // `configuration:` parameter.
    .library(
      name: "IMGLYPluginVoiceIsolation",
      targets: ["IMGLYPluginVoiceIsolation"],
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/imgly/IMGLYUI-swift.git", exact: "1.86.0"),
    // Versioned on its own, so the release bump leaves this pin. A patch release is a packaging fix and reaches
    // released plugins; a new ONNX Runtime version raises the minor version and does not.
    .package(url: "https://github.com/imgly/IMGLYONNXRuntime-swift.git", .upToNextMinor(from: "1.0.0")),
  ],
  targets: [
    .target(
      name: "IMGLYPluginVoiceIsolationCore",
      dependencies: [
        .product(name: "IMGLYUI", package: "IMGLYUI-swift"),
      ],
      // Explicit so SPM generates `Bundle.module`, which `LocalizedStringResource+.swift` references.
      resources: [
        .process("IMGLYPluginVoiceIsolation.xcstrings"),
      ],
    ),
    .target(
      name: "IMGLYPluginVoiceIsolationONNX",
      dependencies: [
        .target(name: "IMGLYPluginVoiceIsolationCore"),
        .product(name: "IMGLYONNXRuntime", package: "IMGLYONNXRuntime-swift"),
      ],
    ),
    .target(
      name: "IMGLYPluginVoiceIsolation",
      dependencies: [
        .target(name: "IMGLYPluginVoiceIsolationCore"),
        .target(name: "IMGLYPluginVoiceIsolationONNX"),
      ],
    ),
    .testTarget(
      name: "IMGLYPluginVoiceIsolationTests",
      dependencies: ["IMGLYPluginVoiceIsolation"],
      resources: [
        .copy("Fixtures"),
      ],
    ),
  ],
)
