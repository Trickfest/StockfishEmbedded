// swift-tools-version: 6.2

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

// The target spans this repository so it can compile the vendored Stockfish
// sources. Keep private C++ headers out of SwiftPM's Objective-C API extraction
// for DocC; the compiler can still include them from the source files.
let privateHeaderPaths = ["Sources/SFEngine", "ThirdParty/Stockfish/src"]
    .flatMap { directory -> [String] in
        let path = packageRoot.appendingPathComponent(directory).path
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return []
        }
        return enumerator.allObjects.compactMap { $0 as? String }
            .filter { path in
                (path.hasSuffix(".h") || path.hasSuffix(".hh") || path.hasSuffix(".hpp"))
                    && !(directory == "Sources/SFEngine" && path.hasPrefix("include/"))
            }
            .map { "\(directory)/\($0)" }
    }
    .sorted()

let nonPackageDirectories = [
    "IOSSwiftUI",
    "Sources/CLIObjC",
    "Sources/CLISoakSwift",
    "Sources/CLISwift",
    "Sources/SFEngineSoak",
    "Tests",
]
let localBuildDirectory = packageRoot.appendingPathComponent("build").path
let excludedGeneratedBuild = FileManager.default.fileExists(atPath: localBuildDirectory)
    ? ["build"] : []

let stockfishCoreSources = [
    "Sources/SFEngine/EmbeddedUCI.cpp",
    "Sources/SFEngine/SFEngine.mm",
    "ThirdParty/Stockfish/src/memory.cpp",
    "ThirdParty/Stockfish/src/thread.cpp",
    "ThirdParty/Stockfish/src/timeman.cpp",
    "ThirdParty/Stockfish/src/ucioption.cpp",
    "ThirdParty/Stockfish/src/nnue/network.cpp",
    "ThirdParty/Stockfish/src/nnue/nnue_accumulator.cpp",
    "ThirdParty/Stockfish/src/nnue/features/half_ka_v2_hm.cpp",
    "ThirdParty/Stockfish/src/nnue/features/full_threats.cpp",
    "ThirdParty/Stockfish/src/nnue/features/pp_3wide.cpp",
    "ThirdParty/Stockfish/src/nnue/nnue_misc.cpp",
    "ThirdParty/Stockfish/src/misc.cpp",
    "ThirdParty/Stockfish/src/bitboard.cpp",
    "ThirdParty/Stockfish/src/attacks.cpp",
    "ThirdParty/Stockfish/src/score.cpp",
    "ThirdParty/Stockfish/src/benchmark.cpp",
    "ThirdParty/Stockfish/src/movepick.cpp",
    "ThirdParty/Stockfish/src/tune.cpp",
    "ThirdParty/Stockfish/src/syzygy/tbprobe.cpp",
    "Sources/SFEngine/StockfishEvaluate.cpp",
    "ThirdParty/Stockfish/src/search.cpp",
    "ThirdParty/Stockfish/src/engine.cpp",
    "ThirdParty/Stockfish/src/movegen.cpp",
    "ThirdParty/Stockfish/src/tt.cpp",
    "ThirdParty/Stockfish/src/position.cpp",
    "ThirdParty/Stockfish/src/uci.cpp",
]

let package = Package(
    name: "StockfishEmbedded",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SFEngine",
            targets: ["SFEngine"]
        ),
    ],
    targets: [
        .target(
            name: "SFEngine",
            path: ".",
            exclude: nonPackageDirectories + privateHeaderPaths + excludedGeneratedBuild,
            sources: stockfishCoreSources,
            publicHeadersPath: "Sources/SFEngine/include",
            cxxSettings: [
                .headerSearchPath("Sources/SFEngine"),
                .headerSearchPath("ThirdParty/Stockfish/src"),
                .define("IS_64BIT"),
                .define("USE_POPCNT"),
                // PackageDescription cannot select settings by architecture.
                // NEON intentionally makes this package Apple-arm64-only.
                .define("USE_NEON", to: "8"),
                // A clean package build does not require the ignored NNUE file.
                // Runtime clients provide a local network URL to SFEngine.
                .define("NNUE_EMBEDDING_OFF"),
                .define("NDEBUG", .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "SFEnginePackageTests",
            dependencies: ["SFEngine"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
