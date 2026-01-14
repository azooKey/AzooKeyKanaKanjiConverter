// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

var swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .interoperabilityMode(.Cxx, .when(traits: ["Zenzai", "ZenzaiCPU"]))
]

var coreMLMacOSLinkFlags: [String] = []
#if os(macOS)
// CoreML XCFrameworks are built for macOS 15.5+. When the CoreML trait is enabled,
// apply a platform_version hint at link time to silence version mismatch warnings.
coreMLMacOSLinkFlags = ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "15.0", "-Xlinker", "15.0"]
#endif

var dependencies: [Package.Dependency] = [
    // Dependencies declare other packages that this package depends on.
    // .package(url: /* package url */, from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-algorithms", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.0.0")),
    .package(url: "https://github.com/Skyline-23/swift-transformers.git", branch: "feature/increase-compatibility")
]

#if os(macOS) || os(iOS) 
dependencies.append(
    .package(
        url: "https://github.com/Skyline-23/zenz-CoreML.git",
        from: "3.1.1"
    )
)
#endif

var efficientNGramDependencies: [Target.Dependency] = [
    .product(name: "Tokenizers", package: "swift-transformers"),
    .product(name: "Hub", package: "swift-transformers")
]

#if (!os(Linux) || !canImport(Android)) && !os(Windows)
// Android環境・Windows環境ではSwiftyMarisaが利用できないため、EfficientNGramは除外する。
dependencies.append(.package(url: "https://github.com/ensan-hcl/SwiftyMarisa", from: "0.0.1"))
efficientNGramDependencies.append(.product(name: "SwiftyMarisa", package: "SwiftyMarisa", condition: .when(traits: ["Zenzai", "ZenzaiCPU"])))
#endif


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
        name: "EfficientNGram",
        dependencies: efficientNGramDependencies,
        resources: [.copy("tokenizer")],
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
        ],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "SwiftUtilsTests",
        dependencies: ["SwiftUtils"],
        resources: [],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "EfficientNGramTests",
        dependencies: ["EfficientNGram"],
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

#if os(macOS) || os(iOS)
targets.append(
    .target(
        name: "ZenzCoreMLBackend",
        dependencies: [
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(
                name: "ZenzCoreMLStateful8bit",
                package: "zenz-CoreML",
                condition: .when(traits: ["ZenzaiCoreML"])
            )
        ],
        resources: [],
        swiftSettings: swiftSettings,
        linkerSettings: coreMLMacOSLinkFlags.isEmpty ? [] : [.unsafeFlags(coreMLMacOSLinkFlags, .when(traits: ["ZenzaiCoreML"]))]
    )
)
#endif

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

#if os(Windows) || os(Linux)
let llamaCppTarget: Target = .systemLibrary(name: "llama.cpp")
#else
let llamaCppTarget: Target = .binaryTarget(
    name: "llama.cpp",
    url: "https://github.com/azooKey/llama.cpp/releases/download/b4846/signed-llama.xcframework.zip",
    // this can be computed `swift package compute-checksum llama-b4844-xcframework.zip`
    checksum: "db3b13169df8870375f212e6ac21194225f1c85f7911d595ab64c8c790068e0a"
)
#endif
targets.append(llamaCppTarget)
var kanaKanjiDependencies: [Target.Dependency] = [
    "SwiftUtils",
    .target(name: "EfficientNGram"),
    .target(name: "llama.cpp", condition: .when(traits: ["Zenzai", "ZenzaiCPU"])),
    .product(name: "Collections", package: "swift-collections")
]

#if os(macOS) || os(iOS)
kanaKanjiDependencies.append(.target(name: "ZenzCoreMLBackend", condition: .when(traits: ["ZenzaiCoreML"])))
#endif

targets.append(
    .target(
        name: "KanaKanjiConverterModule",
        dependencies: kanaKanjiDependencies,
        swiftSettings: swiftSettings,
        linkerSettings: coreMLMacOSLinkFlags.isEmpty ? [] : [.unsafeFlags(coreMLMacOSLinkFlags, .when(traits: ["ZenzaiCoreML"]))]
    )
)

#if os(macOS) || os(iOS)
let packageTraits: Set<PackageDescription.Trait> = [
    .trait(name: "Zenzai"),
    .trait(name: "ZenzaiCPU"),
    .trait(name: "ZenzaiCoreML"),
    .default(enabledTraits: [])
]
#else
let packageTraits: Set<PackageDescription.Trait> = [
    .trait(name: "Zenzai"),
    .trait(name: "ZenzaiCPU"),
    .default(enabledTraits: [])
]
#endif

let package = Package(
    name: "AzooKeyKanaKanjiConverter",
    platforms: [.iOS(.v16), .macOS(.v13)],
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
    traits: packageTraits,
    dependencies: dependencies,
    targets: targets
)
