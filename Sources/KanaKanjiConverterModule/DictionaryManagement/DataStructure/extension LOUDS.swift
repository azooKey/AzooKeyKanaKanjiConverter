//
//  extension Data.swift
//  Keyboard
//
//  Created by ensan on 2020/09/30.
//  Copyright © 2020 ensan. All rights reserved.
//

package import Foundation
import SwiftUtils

extension LOUDS {
    // MARK: - Unaligned-safe little-endian readers
    @inline(__always)
    private static func byte(_ data: borrowing Data, _ offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }

    @inline(__always)
    private static func readUInt16LE(_ data: borrowing Data, _ offset: Int) -> UInt16 {
        let b0 = UInt16(byte(data, offset))
        let b1 = UInt16(byte(data, offset + 1))
        return b0 | (b1 << 8)
    }

    @inline(__always)
    private static func readUInt32LE(_ data: borrowing Data, _ offset: Int) -> UInt32 {
        let b0 = UInt32(byte(data, offset))
        let b1 = UInt32(byte(data, offset + 1))
        let b2 = UInt32(byte(data, offset + 2))
        let b3 = UInt32(byte(data, offset + 3))
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    @inline(__always)
    private static func readFloat32LE(_ data: borrowing Data, _ offset: Int) -> Float32 {
        Float32(bitPattern: readUInt32LE(data, offset))
    }
    private static func loadLOUDSBinary(from url: URL) -> [UInt64]? {
        do {
            let binaryData = try Data(contentsOf: url, options: [.uncached, .mappedIfSafe]) // 2度読み込むことはないのでキャッシュ不要
            return binaryData.toArray(of: UInt64.self)
        } catch {
            debug(error)
            return nil
        }
    }

    /// LOUDSをファイルから読み込む関数
    /// - Parameter identifier: ファイル名
    /// - Returns: 存在すればLOUDSデータを返し、存在しなければ`nil`を返す。
    package static func load(_ identifier: String, dictionaryURL: URL) -> LOUDS? {
        let (charsURL, loudsURL) = (
            dictionaryURL.appendingPathComponent("louds/\(identifier).loudschars2", isDirectory: false),
            dictionaryURL.appendingPathComponent("louds/\(identifier).louds", isDirectory: false)
        )
        return load(charsURL: charsURL, loudsURL: loudsURL)
    }

    package static func loadMemory(memoryURL: URL) -> LOUDS? {
        let (charsURL, loudsURL) = (
            memoryURL.appendingPathComponent("memory.loudschars2", isDirectory: false),
            memoryURL.appendingPathComponent("memory.louds", isDirectory: false)
        )
        return load(charsURL: charsURL, loudsURL: loudsURL)
    }

    package static func loadUserDictionary(userDictionaryURL: URL) -> LOUDS? {
        let (charsURL, loudsURL) = (
            userDictionaryURL.appending(path: "user.loudschars2", directoryHint: .notDirectory),
            userDictionaryURL.appending(path: "user.louds", directoryHint: .notDirectory)
        )
        return load(charsURL: charsURL, loudsURL: loudsURL)
    }

    package static func loadUserShortcuts(userDictionaryURL: URL) -> LOUDS? {
        let (charsURL, loudsURL) = (
            userDictionaryURL.appending(path: "user_shortcuts.loudschars2", directoryHint: .notDirectory),
            userDictionaryURL.appending(path: "user_shortcuts.louds", directoryHint: .notDirectory)
        )
        return load(charsURL: charsURL, loudsURL: loudsURL)
    }

    private static func load(charsURL: URL, loudsURL: URL) -> LOUDS? {
        let nodeIndex2ID: [UInt8]
        do {
            nodeIndex2ID = try Array(Data(contentsOf: charsURL, options: [.uncached]))   // 2度読み込むことはないのでキャッシュ不要
        } catch {
            debug("Error: \(loudsURL)に対するLOUDSファイルが存在しません。このエラーは無視できる可能性があります。 Description: \(error)")
            return nil
        }

        if let bytes = LOUDS.loadLOUDSBinary(from: loudsURL) {
            return LOUDS(bytes: bytes.map {$0.littleEndian}, nodeIndex2ID: nodeIndex2ID)
        }
        return nil
    }

    /// Reject the whole ruby group if its fields cannot be matched to the numeric rows.
    @inlinable
    static func parseBinary(binary: borrowing Data) -> [DicdataElement] {
        guard binary.count >= 2 else {
            return []
        }
        let count = Int(readUInt16LE(binary, 0))
        // Each row contains three UInt16 IDs and one Float32 score.
        guard count > 0, count <= (binary.count - 2) / 10 else {
            return []
        }
        let textStart = 2 + count * 10

        return binary.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var fieldStart = textStart
            var ruby: String?
            var dicdata: [DicdataElement] = []
            dicdata.reserveCapacity(count)
            // Include the end position so a trailing empty word is preserved.
            for offset in textStart ... bytes.count {
                if offset == bytes.count || bytes[offset] == UInt8(ascii: "\t") {
                    guard let field = String(bytes: bytes[fieldStart ..< offset], encoding: .utf8) else {
                        return []
                    }
                    if let ruby {
                        guard dicdata.count < count else {
                            return []
                        }
                        let rowOffset = 2 + dicdata.count * 10
                        dicdata.append(DicdataElement(
                            word: field.isEmpty ? ruby : field,
                            ruby: ruby,
                            lcid: Int(readUInt16LE(binary, rowOffset)),
                            rcid: Int(readUInt16LE(binary, rowOffset + 2)),
                            mid: Int(readUInt16LE(binary, rowOffset + 4)),
                            value: PValue(readFloat32LE(binary, rowOffset + 6))
                        ))
                    } else {
                        guard !field.isEmpty else {
                            return []
                        }
                        ruby = field
                    }
                    fieldStart = offset + 1
                }
            }
            return dicdata.count == count ? dicdata : []
        }
    }

    static func getUserDictionaryDataForLoudstxt3(_ identifier: String, indices: [Int], cache: Data? = nil, userDictionaryURL: URL) -> [DicdataElement] {
        if let cache {
            return Self.parseLoudstxt3Binary(binary: cache, indices: indices)
        }
        do {
            let url = userDictionaryURL.appendingPathComponent("\(identifier).loudstxt3", isDirectory: false)
            return Self.parseLoudstxt3Binary(binary: try Data(contentsOf: url), indices: indices)
        } catch {
            debug(#function, error)
            return []
        }
    }

    static func getUserShortcutsDataForLoudstxt3(_ identifier: String, indices: [Int], cache: Data? = nil, userDictionaryURL: URL) -> [DicdataElement] {
        if let cache {
            return Self.parseLoudstxt3Binary(binary: cache, indices: indices)
        }
        do {
            let url = userDictionaryURL.appendingPathComponent("\(identifier).loudstxt3", isDirectory: false)
            return Self.parseLoudstxt3Binary(binary: try Data(contentsOf: url), indices: indices)
        } catch {
            debug(#function, error)
            return []
        }
    }

    static func getMemoryDataForLoudstxt3(_ identifier: String, indices: [Int], cache: Data? = nil, memoryURL: URL) -> [DicdataElement] {
        if let cache {
            return Self.parseLoudstxt3Binary(binary: cache, indices: indices)
        }
        do {
            let url = memoryURL.appendingPathComponent("\(identifier).loudstxt3", isDirectory: false)
            return Self.parseLoudstxt3Binary(binary: try Data(contentsOf: url), indices: indices)
        } catch {
            debug(#function, error)
            return []
        }
    }

    static func getDataForLoudstxt3(_ identifier: String, indices: [Int], cache: Data? = nil, dictionaryURL: URL) -> [DicdataElement] {
        if let cache {
            return Self.parseLoudstxt3Binary(binary: cache, indices: indices)
        }
        do {
            let url = dictionaryURL.appendingPathComponent("louds/\(identifier).loudstxt3", isDirectory: false)
            return Self.parseLoudstxt3Binary(binary: try Data(contentsOf: url, options: [.mappedIfSafe]), indices: indices)
        } catch {
            debug(#function, error)
            return []
        }
    }

    /// Validate the complete offset table before any entry is read.
    static func loudstxt3EntryCount(binary: borrowing Data) -> Int? {
        guard binary.count >= 2 else {
            return nil
        }
        let count = Int(readUInt16LE(binary, 0))
        guard count <= (binary.count - 2) / 4 else {
            return nil
        }
        return count
    }

    static func parseLoudstxt3Binary(binary: borrowing Data, indices: [Int]) -> [DicdataElement] {
        guard let count = loudstxt3EntryCount(binary: binary) else {
            return []
        }
        let headerSize = 2 + count * 4
        var out: [DicdataElement] = []
        out.reserveCapacity(indices.count * 2)
        for idx in indices {
            guard idx >= 0, idx < count else { continue }
            let start = Int(readUInt32LE(binary, 2 + idx * 4))
            let end = idx == count - 1 ? binary.count : Int(readUInt32LE(binary, 2 + (idx + 1) * 4))
            guard start >= headerSize, start < end, end <= binary.count else { continue }
            let base = binary.startIndex
            out.append(contentsOf: parseBinary(binary: binary[(base + start) ..< (base + end)]))
        }
        return out
    }
}
