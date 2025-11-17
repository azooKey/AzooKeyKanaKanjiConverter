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
    private static let bundleIdentifier = "com.skyline23.ZenzCoreML.Stateful8bit"
    private static let modelFileName = "zenz_v3.1_stateful-8bit"

    @MainActor
    static func loadStateful8bit(configuration: MLModelConfiguration) throws -> MLModel {
        let modelURL = try modelURL()
        return try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    @MainActor
    static func tokenizerDirectory() throws -> URL {
        try bundle().url(
            forResource: "tokenizer",
            withExtension: nil
        ).unwrapped(or: ZenzCoreMLError.tokenizerNotFound)
    }

    @MainActor
    private static func modelURL() throws -> URL {
        try bundle().url(
            forResource: modelFileName,
            withExtension: "mlmodelc"
        ).unwrapped(or: ZenzCoreMLError.modelNotFound)
    }

    @MainActor
    private static func bundle() throws -> Bundle {
        if let bundle = Bundle(identifier: bundleIdentifier) {
            return bundle
        }
#if SWIFT_PACKAGE
        if let bundle = Bundle(path: Bundle.main.bundlePath + "/\(bundleIdentifier).bundle") {
            return bundle
        }
#endif
        throw ZenzCoreMLError.bundleNotFound
    }
}

private extension Optional {
    func unwrapped(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let value = self else {
            throw error()
        }
        return value
    }
}
