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
        guard offset >= 0, offset < data.count else { return 0 }
        return data[data.index(data.startIndex, offsetBy: offset)]
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

    @inlinable
    static func parseBinary(binary: borrowing Data) -> [DicdataElement] {
        // Fast parse without intermediate toArray allocations
        let count = Int(readUInt16LE(binary, 0))
        var offset = 2
        var dicdata: [DicdataElement] = []
        dicdata.reserveCapacity(count)
        if count > 0 {
            // Each entry: 2B*3 (UInt16) + 4B (Float32) = 10B
            for _ in 0 ..< count {
                let lcid = Int(readUInt16LE(binary, offset + 0))
                let rcid = Int(readUInt16LE(binary, offset + 2))
                let mid = Int(readUInt16LE(binary, offset + 4))
                let value = PValue(readFloat32LE(binary, offset + 6))
                dicdata.append(DicdataElement(word: "", ruby: "", lcid: lcid, rcid: rcid, mid: mid, value: value))
                offset += 10
            }
        }

        let strStart = binary.index(binary.startIndex, offsetBy: offset)
        var rangeStart = strStart
        var ruby: String = ""
        var i = dicdata.startIndex

        binary.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            let count = binary.count
            var offset = strStart + 1 - binary.startIndex
            while offset <= count {
                if offset == count || ptr[offset] == UInt8(ascii: "\t") {
                    // Compute numeric start relative to base
                    let startInt = rangeStart - binary.startIndex
                    let length = offset - startInt
                    let isFirstField = (rangeStart == strStart)
                    let isEmptyField = (length == 0)

                    // Corrupted files may contain more tab-separated fields than
                    // declared entries. Writing to dicdata[i] out of bounds traps
                    // (SIGILL); stop parsing instead.
                    guard i < dicdata.count else {
                        return
                    }

                    if isFirstField {
                        let rb = UnsafeBufferPointer(start: ptr + startInt, count: length)
                        ruby = String(decoding: rb, as: UTF8.self)
                    } else if isEmptyField {
                        withMutableValue(&dicdata[i]) {
                            $0.ruby = ruby
                            $0.word = ruby
                        }
                        i = dicdata.index(after: i)
                    } else {
                        let wb = UnsafeBufferPointer(start: ptr + startInt, count: length)
                        let word = String(decoding: wb, as: UTF8.self)
                        withMutableValue(&dicdata[i]) {
                            $0.ruby = ruby
                            $0.word = word
                        }
                        i = dicdata.index(after: i)
                    }
                    rangeStart = binary.startIndex + offset + 1
                    offset += 1
                } else {
                    offset += 1
                }
            }
        }
        return dicdata
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

    private static func parseLoudstxt3Binary(binary: borrowing Data, indices: [Int]) -> [DicdataElement] {
        let lc: Int = Int(readUInt16LE(binary, 0))
        // Header table of UInt32 offsets starts at byte 2
        var out: [DicdataElement] = []
        out.reserveCapacity(indices.count * 2) // rough guess
        for idx in indices {
            // Guard against corrupted / out-of-range entries:
            // An out-of-bounds subscript on Data traps (SIGILL via ud2) and kills
            // the whole process (e.g. hazkey-server), so skip invalid indices and
            // inverted ranges instead of trapping.
            guard idx >= 0, idx < lc else { continue }
            let start = Int(readUInt32LE(binary, 2 + idx * 4))
            let end: Int = if idx == (lc - 1) {
                binary.endIndex
            } else {
                Int(readUInt32LE(binary, 2 + (idx + 1) * 4))
            }
            guard start < end, end <= binary.count, start >= 2 + lc * 4 else { continue }
            out.append(contentsOf: parseBinary(binary: binary[start ..< end]))
        }
        return out
    }
}
