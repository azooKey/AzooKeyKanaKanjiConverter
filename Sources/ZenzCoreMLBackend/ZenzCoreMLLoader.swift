//
//  ZenzCoreMLLoader.swift
//  AzooKeyKanaKanjiConverter
//
//  Created by OpenAI on 2024/11/16.
//

@preconcurrency import CoreML
import Foundation

@available(iOS 18.0, macOS 15.0, *)
enum ZenzCoreMLLoader {
    private static let repoID = "Skyline23/zenz-coreml"

    private struct AssetLocations {
        var compiledModelURL: URL
        var tokenizerDirectoryURL: URL
    }

    private static var modelPackageRelativePath: String {
        let variant = ProcessInfo.processInfo.environment["AZOO_KEY_COREML_VARIANT"]?.lowercased()
        if variant == "8bit" {
            return "Artifacts/stateful/zenz-stateful-8bit.mlpackage"
        }
        return "Artifacts/stateful/zenz-stateful-fp16.mlpackage"
    }

    private static var compiledModelName: String {
        let variant = ProcessInfo.processInfo.environment["AZOO_KEY_COREML_VARIANT"]?.lowercased()
        return variant == "8bit" ? "zenz-stateful-8bit.mlmodelc" : "zenz-stateful-fp16.mlmodelc"
    }

    static func loadStateful8bit(configuration: MLModelConfiguration) async throws -> MLModel {
        let assets = try await ensureAssets()
        do {
            return try MLModel(contentsOf: assets.compiledModelURL, configuration: configuration)
        } catch {
            throw ZenzCoreMLError.modelCompileFailed(error.localizedDescription)
        }
    }

    static func tokenizerDirectory() async throws -> URL {
        try await ensureAssets().tokenizerDirectoryURL
    }

    private static func ensureAssets() async throws -> AssetLocations {
        let cacheRoot = try cacheRootDirectory()
        if let cached = existingCompiledAssets(in: cacheRoot) {
            return cached
        }
        let sourceRoot = try await ensureSourceRoot(cacheRoot: cacheRoot)
        let compiledRoot = cacheRoot.appendingPathComponent("compiled", isDirectory: true)
        let tokenizerDirectoryURL = sourceRoot.appendingPathComponent("tokenizer", isDirectory: true)
        let modelPackageURL = sourceRoot.appendingPathComponent(modelPackageRelativePath, isDirectory: true)
        let compiledModelURL = compiledRoot.appendingPathComponent("\(sourceRoot.lastPathComponent)-\(compiledModelName)", isDirectory: true)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: compiledRoot, withIntermediateDirectories: true)

        guard hasRequiredAssets(in: sourceRoot) else {
            throw ZenzCoreMLError.downloadFailed
        }

        let shouldCompile: Bool
        if !fileManager.fileExists(atPath: compiledModelURL.path(percentEncoded: false)) {
            shouldCompile = true
        } else if let compiledDate = try? compiledModelURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  let sourceDate = try? modelPackageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            shouldCompile = sourceDate > compiledDate
        } else {
            shouldCompile = false
        }

        if shouldCompile {
            let temporaryCompiledURL: URL
            do {
                temporaryCompiledURL = try await MLModel.compileModel(at: modelPackageURL)
            } catch {
                throw ZenzCoreMLError.modelCompileFailed(error.localizedDescription)
            }
            if fileManager.fileExists(atPath: compiledModelURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: compiledModelURL)
            }
            do {
                try fileManager.moveItem(at: temporaryCompiledURL, to: compiledModelURL)
            } catch {
                throw ZenzCoreMLError.modelCompileFailed(error.localizedDescription)
            }
        }

        return .init(compiledModelURL: compiledModelURL, tokenizerDirectoryURL: tokenizerDirectoryURL)
    }

    private static func cacheRootDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["AZOO_KEY_COREML_CACHE_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = base.appendingPathComponent("AzooKeyKanaKanjiConverter/zenz-coreml", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func ensureSourceRoot(cacheRoot: URL) async throws -> URL {
        if let override = explicitSourceRoot(from: cacheRoot) {
            return override
        }
        if let snapshot = huggingFaceSnapshotRoot() {
            return snapshot
        }
        let downloadedRoot = cacheRoot.appendingPathComponent("downloaded", isDirectory: true)
        if hasRequiredAssets(in: downloadedRoot) {
            return downloadedRoot
        }
        return try runSnapshotDownload(localDir: downloadedRoot, cacheRoot: cacheRoot)
    }

    private static func explicitSourceRoot(from cacheRoot: URL) -> URL? {
        let candidates = [
            cacheRoot,
            cacheRoot.appendingPathComponent("downloaded", isDirectory: true)
        ]
        return candidates.first(where: hasRequiredAssets)
    }

    private static func existingCompiledAssets(in cacheRoot: URL) -> AssetLocations? {
        let tokenizerCandidates = [
            cacheRoot.appendingPathComponent("tokenizer", isDirectory: true),
            cacheRoot.appendingPathComponent("downloaded/tokenizer", isDirectory: true)
        ]
        guard let tokenizerDirectoryURL = tokenizerCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("tokenizer.json").path(percentEncoded: false))
        }) else {
            return nil
        }

        let compiledRoot = cacheRoot.appendingPathComponent("compiled", isDirectory: true)
        let compiledModelURL = compiledRoot.appendingPathComponent(compiledModelName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: compiledModelURL.path(percentEncoded: false)) else {
            return nil
        }

        return .init(compiledModelURL: compiledModelURL, tokenizerDirectoryURL: tokenizerDirectoryURL)
    }

    private static func huggingFaceSnapshotRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let hfHome: URL
        if let override = env["HF_HOME"], !override.isEmpty {
            hfHome = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            hfHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface", isDirectory: true)
        }
        let snapshotsRoot = hfHome
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent("models--Skyline23--zenz-coreml", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotDirectories = try? FileManager.default.contentsOfDirectory(
            at: snapshotsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return snapshotDirectories
            .filter(hasRequiredAssets)
            .sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private static func hasRequiredAssets(in root: URL) -> Bool {
        let fileManager = FileManager.default
        let tokenizerFile = root.appendingPathComponent("tokenizer/tokenizer.json", isDirectory: false)
        let manifestFile = root.appendingPathComponent("\(modelPackageRelativePath)/Manifest.json", isDirectory: false)
        return fileManager.fileExists(atPath: tokenizerFile.path(percentEncoded: false))
            && fileManager.fileExists(atPath: manifestFile.path(percentEncoded: false))
    }

    private static func runSnapshotDownload(localDir: URL, cacheRoot: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            "-c",
            """
from huggingface_hub import snapshot_download
path = snapshot_download(
    repo_id="\(repoID)",
    repo_type="model",
    cache_dir=r"\(cacheRoot.appendingPathComponent("hf-hub", isDirectory: true).path(percentEncoded: false))",
    local_dir=r"\(localDir.path(percentEncoded: false))",
    allow_patterns=["\(modelPackageRelativePath)/**", "tokenizer/*", "hf_manifest.json"],
)
print(path)
"""
        ]
        var environment = ProcessInfo.processInfo.environment
        if environment["HF_HOME"] == nil {
            environment["HF_HOME"] = cacheRoot.appendingPathComponent("hf-home", isDirectory: true).path(percentEncoded: false)
        }
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ZenzCoreMLError.downloadFailed
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let output = String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init),
            !output.isEmpty
        else {
            throw ZenzCoreMLError.downloadFailed
        }
        let url = URL(fileURLWithPath: output, isDirectory: true)
        guard hasRequiredAssets(in: url) else {
            throw ZenzCoreMLError.downloadFailed
        }
        return url
    }
}
