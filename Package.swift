// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .enableUpcomingFeature("ConciseMagicFile"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ForwardTrailingClosures"),
    .enableUpcomingFeature("ImplicitOpenExistentials"),
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("ImportObjcForwardDeclarations")
]

var dependencies: [Package.Dependency] = [
    // Dependencies declare other packages that this package depends on.
    // .package(url: /* package url */, from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-algorithms", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.0.0"))
]

var targets: [Target] = [
    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
    // Targets can depend on other targets in this package, and on products in packages this package depends on.
    .target(
        name: "SwiftUtils",
        dependencies: [
            .product(name: "Algorithms", package: "swift-algorithms")
        ],
        resources: [],
        swiftSettings: swiftSettings
    ),
    .target(
        name: "KanaKanjiConverterModuleWithDefaultDictionary",
        dependencies: [
            "KanaKanjiConverterModule"
        ],
        exclude: [
            "azooKey_dictionary_storage/README.md",
            "azooKey_dictionary_storage/LICENSE",
            "azooKey_emoji_dictionary_storage/data",
            "azooKey_emoji_dictionary_storage/scripts",
            "azooKey_emoji_dictionary_storage/requirements.txt",
            "azooKey_emoji_dictionary_storage/README.md",
        ],
        resources: [
            .copy("azooKey_dictionary_storage/Dictionary"),
            .copy("azooKey_emoji_dictionary_storage/EmojiDictionary"),
        ],
        swiftSettings: swiftSettings
    ),
    .executableTarget(
        name: "CliTool",
        dependencies: [
            "KanaKanjiConverterModuleWithDefaultDictionary",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .testTarget(
        name: "SwiftUtilsTests",
        dependencies: ["SwiftUtils"],
        resources: [],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "KanaKanjiConverterModuleTests",
        dependencies: ["KanaKanjiConverterModule"],
        resources: [
            .copy("DictionaryMock")
        ],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "KanaKanjiConverterModuleWithDefaultDictionaryTests",
        dependencies: [
            "KanaKanjiConverterModuleWithDefaultDictionary",
            .product(name: "Collections", package: "swift-collections")
        ],
        swiftSettings: swiftSettings
    )
]

#if os(Linux) && !canImport(Android)
func checkObjcAvailability() -> Bool {
    do {
        let linkCheck = Process()
        linkCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
        linkCheck.arguments = ["-c", "echo 'int main() { return 0; }' | clang -x c - -lobjc -o /dev/null"]
        
        try linkCheck.run()
        linkCheck.waitUntilExit()
        
        if linkCheck.terminationStatus != 0 {
            print("Cannot link with -lobjc")
            return false
        }
        return true
    } catch {
        print("Error checking Objective-C availability: \(error)")
        return false
    }
}

if checkObjcAvailability() {
    print("Objective-C runtime is available")
    targets = targets.map { target in
        if target.name == "CliTool" || target.name == "KanaKanjiConverterModuleWithDefaultDictionaryTests" {
        let modifiedTarget = target
        modifiedTarget.linkerSettings = [.linkedLibrary("objc")]
        return modifiedTarget
        }
        return target
    }
}
#endif

#if os(Windows)
targets.append(contentsOf: [
    .systemLibrary(
        name: "llama.cpp"
    ),
    .target(
        name: "KanaKanjiConverterModule",
        dependencies: [
            "SwiftUtils",
            "llama.cpp",
            .product(name: "Collections", package: "swift-collections")
        ],
        swiftSettings: swiftSettings
    )
])
#else
if let envValue = ProcessInfo.processInfo.environment["LLAMA_MOCK"], envValue == "1" {
    targets.append(contentsOf: [
        .target(name: "llama-mock"),
        .target(
            name: "KanaKanjiConverterModule",
            dependencies: [
                "SwiftUtils",
                "llama-mock",
                .product(name: "Collections", package: "swift-collections")
            ],
            swiftSettings: swiftSettings
        )
    ])
} else {
    dependencies.append(
        .package(url: "https://github.com/ensan-hcl/llama.cpp", branch: "6b862f4")
    )

    targets.append(contentsOf: [
        .target(
            name: "KanaKanjiConverterModule",
            dependencies: [
                "SwiftUtils",
                .product(name: "llama", package: "llama.cpp"),
                .product(name: "Collections", package: "swift-collections")
            ],
            swiftSettings: swiftSettings
        )
    ])
}
#endif

let package = Package(
    name: "AzooKeyKanakanjiConverter",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "SwiftUtils",
            targets: ["SwiftUtils"]
        ),
        /// デフォルト辞書データを含むバージョンの辞書モジュール
        .library(
            name: "KanaKanjiConverterModuleWithDefaultDictionary",
            targets: ["KanaKanjiConverterModuleWithDefaultDictionary"]
        ),
        /// 辞書データを含まないバージョンの辞書モジュール
        .library(
            name: "KanaKanjiConverterModule",
            targets: ["KanaKanjiConverterModule"]
        ),
    ],
    dependencies: dependencies,
    targets: targets
)
