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
    private static let resolveBaseURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main")!
    private static let modelAPIURL = URL(string: "https://huggingface.co/api/models/\(repoID)")!
    private static let modelPackageRelativePath = "Artifacts/stateful/zenz-stateful-8bit.mlpackage"
    private static let tokenizerFileRelativePaths = [
        "tokenizer/config.json",
        "tokenizer/merges.txt",
        "tokenizer/special_tokens_map.json",
        "tokenizer/tokenizer.json",
        "tokenizer/tokenizer_config.json",
        "tokenizer/vocab.json"
    ]
    private static let modelPackageFileRelativePaths = [
        "\(modelPackageRelativePath)/Manifest.json",
        "\(modelPackageRelativePath)/Data/com.apple.CoreML/model.mlmodel",
        "\(modelPackageRelativePath)/Data/com.apple.CoreML/weights/weight.bin"
    ]

    private struct AssetLocations {
        var compiledModelURL: URL
        var tokenizerDirectoryURL: URL
    }

    private struct ModelMetadata: Decodable {
        var sha: String
    }

    static func loadStateful8bit(configuration: MLModelConfiguration) async throws -> MLModel {
        let assets = try await ensureAssets()
        return try MLModel(contentsOf: assets.compiledModelURL, configuration: configuration)
    }

    static func tokenizerDirectory() async throws -> URL {
        try await ensureAssets().tokenizerDirectoryURL
    }

    private static func ensureAssets() async throws -> AssetLocations {
        let cacheRoot = try cacheRootDirectory()
        let downloadedRoot = cacheRoot.appendingPathComponent("downloaded", isDirectory: true)
        let compiledRoot = cacheRoot.appendingPathComponent("compiled", isDirectory: true)
        let tokenizerDirectoryURL = downloadedRoot.appendingPathComponent("tokenizer", isDirectory: true)
        let modelPackageURL = downloadedRoot.appendingPathComponent(modelPackageRelativePath, isDirectory: true)
        let compiledModelURL = compiledRoot.appendingPathComponent("zenz-stateful-8bit.mlmodelc", isDirectory: true)
        let revisionFileURL = cacheRoot.appendingPathComponent(".revision", isDirectory: false)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: downloadedRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: compiledRoot, withIntermediateDirectories: true)

        let remoteRevision = try? await fetchRemoteRevision()
        let localRevision = try? String(contentsOf: revisionFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldRefresh = remoteRevision != nil && remoteRevision != localRevision

        if shouldRefresh {
            try? fileManager.removeItem(at: downloadedRoot)
            try? fileManager.removeItem(at: compiledModelURL)
            try fileManager.createDirectory(at: downloadedRoot, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: tokenizerDirectoryURL.path(percentEncoded: false)) {
            for relativePath in tokenizerFileRelativePaths {
                try await download(relativePath: relativePath, into: downloadedRoot)
            }
        }

        if !fileManager.fileExists(atPath: modelPackageURL.path(percentEncoded: false)) {
            for relativePath in modelPackageFileRelativePaths {
                try await download(relativePath: relativePath, into: downloadedRoot)
            }
        }

        if !fileManager.fileExists(atPath: compiledModelURL.path(percentEncoded: false)) {
            let temporaryCompiledURL = try await MLModel.compileModel(at: modelPackageURL)
            if fileManager.fileExists(atPath: compiledModelURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: compiledModelURL)
            }
            try fileManager.moveItem(at: temporaryCompiledURL, to: compiledModelURL)
        }

        if let remoteRevision {
            try remoteRevision.write(to: revisionFileURL, atomically: true, encoding: .utf8)
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

    private static func fetchRemoteRevision() async throws -> String {
        var request = URLRequest(url: modelAPIURL)
        applyAuthorizationHeader(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
        return try JSONDecoder().decode(ModelMetadata.self, from: data).sha
    }

    private static func download(relativePath: String, into root: URL) async throws {
        let destinationURL = root.appendingPathComponent(relativePath, isDirectory: false)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            return
        }
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let remoteURL = resolveBaseURL.appending(path: relativePath)
        var request = URLRequest(url: remoteURL)
        applyAuthorizationHeader(to: &request)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try validate(response: response)
        if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private static func applyAuthorizationHeader(to request: inout URLRequest) {
        let env = ProcessInfo.processInfo.environment
        if let token = env["HF_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let token = env["HUGGINGFACE_HUB_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw ZenzCoreMLError.downloadFailed
        }
    }
}
