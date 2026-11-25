// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PyrowaveKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "PyrowaveKit", targets: ["PyrowaveKit"]),
        .library(name: "CPyrowaveMetal", targets: ["CPyrowaveMetal"]),
        .library(name: "PyrowaveServerKit", targets: ["PyrowaveServerKit"]),
        .library(name: "SPPWCommon", targets: ["SPPWCommon"]),
        .library(name: "PyrowaveGUI", targets: ["PyrowaveGUI"]),
        .executable(name: "pyrowave-swift-bench", targets: ["pyrowave-swift-bench"]),
        .executable(name: "pyrowave-server", targets: ["pyrowave-server"]),
        .executable(name: "pyrowave-server-gui", targets: ["pyrowave-server-gui"]),
        .executable(name: "pyrowave-receiver-gui", targets: ["pyrowave-receiver-gui"]),
        .executable(name: "pyrowave-app", targets: ["pyrowave-app"])
    ],
    targets: [
        .target(
            name: "PyrowaveKit",
            resources: [.process("Metal")]
        ),
        // Vendored upstream PyroWave Metal implementation
        // (https://github.com/Themaister/pyrowave, MIT licensed).
        .target(
            name: "CPyrowaveMetal",
            path: "Vendor/pyrowave-metal",
            sources: [
                "src/pyrowave_common.mm",
                "src/pyrowave_encoder.mm",
                "src/pyrowave_decoder.mm",
                "src/pyrowave_bitstream.cpp"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("src/shaders"),
                .headerSearchPath("include"),
                .define("PYROWAVE_EXPORT_SYMBOLS")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Foundation")
            ]
        ),
        // Shared SPPW/1 wire helpers used by both the server and the receiver.
        // Kept in its own target so the server does not have to depend on the
        // full codec library just for the checksum.
        .target(
            name: "SPPWCommon"
        ),
        // The SPPW/1 streaming server, shared by the command line tool and the
        // SwiftUI application.
        .target(
            name: "PyrowaveServerKit",
            dependencies: ["CPyrowaveMetal", "SPPWCommon"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        // Shared SwiftUI components used by the standalone server GUI,
        // standalone receiver GUI, and the unified pyrowave-app.
        // Contains ServerContentView, ServerModel, ReceiverContentView,
        // ReceiverModel, ReceiverProtocol, LatestFrameDecoder, MetalVideoSurface.
        .target(
            name: "PyrowaveGUI",
            dependencies: ["PyrowaveKit", "PyrowaveServerKit", "SPPWCommon"]
        ),
        .executableTarget(
            name: "pyrowave-swift-bench",
            dependencies: ["PyrowaveKit"]
        ),
        .executableTarget(
            name: "pyrowave-server",
            dependencies: ["PyrowaveServerKit", "SPPWCommon"]
        ),
        .executableTarget(
            name: "pyrowave-server-gui",
            dependencies: ["PyrowaveGUI"]
        ),
        .executableTarget(
            name: "pyrowave-receiver-gui",
            dependencies: ["PyrowaveGUI"]
        ),
        // Unified app — server and receiver in a single window with sidebar
        // navigation. Both panels run simultaneously.
        .executableTarget(
            name: "pyrowave-app",
            dependencies: ["PyrowaveGUI"]
        ),
        .testTarget(
            name: "PyrowaveKitTests",
            dependencies: ["PyrowaveKit", "SPPWCommon", "PyrowaveServerKit"]
        )
    ]
)
