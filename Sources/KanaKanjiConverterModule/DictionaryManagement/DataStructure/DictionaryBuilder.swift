import Collections
public import Foundation

public enum DictionaryBuilder {
    /// Bit width for local index in node index representation.
    /// Change this to re-shard (requires rebuilding all dictionaries).
    public static let shardShift: Int = 11
    /// Number of entries per loudstxt3 shard file (must be power of two).
    public static let entriesPerShard: Int = 1 << shardShift
    /// Bit mask for local index (only valid if entriesPerShard is power of two).
    public static let localMask: Int = entriesPerShard - 1
    /// Export a dictionary from DicdataElement entries into LOUDS and loudstxt3 files.
    /// - Parameters:
    ///   - entries: DicdataElement list (ruby must be consistent form, typically Katakana).
    ///   - directoryURL: Target directory for outputs.
    ///   - baseName: Base file name when not sharding (e.g., "user").
    ///   - shardByFirstCharacter: When true, writes per-first-character files like the default dictionary layout.
    ///   - char2UInt8: Character-ID mapping matching `charID.chid`.
    public static func exportDictionary(
        entries: [DicdataElement],
        to directoryURL: URL,
        baseName: String,
        shardByFirstCharacter: Bool,
        char2UInt8: [Character: UInt8],
        shardShift customShardShift: Int? = nil
    ) throws {
        let effectiveShardShift = customShardShift ?? Self.shardShift
        let effectiveEntriesPerShard = 1 << effectiveShardShift
        let effectiveLocalMask = effectiveEntriesPerShard - 1
        if shardByFirstCharacter {
            let groupedByFirst: [Character: [DicdataElement]] = Dictionary(grouping: entries) { e in e.ruby.first ?? "\0" }
            for (fc, group) in groupedByFirst.sorted(by: { $0.key < $1.key }) {
                let id = escapedIdentifier(String(fc))
                let loudsURL = directoryURL.appendingPathComponent("\(id).louds")
                let charsURL = directoryURL.appendingPathComponent("\(id).loudschars2")
                let (bits, chars) = buildLOUDS(entries: group, char2UInt8: char2UInt8)
                try writeLOUDS(bits: bits, nodes2Characters: chars, loudsURL: loudsURL, loudsChars2URL: charsURL)
                // loudstxt3 shards aligned to LOUDS node indices (entriesPerShard slots per shard)
                let words = makeLOUDSWords(bits: bits)
                let louds = LOUDS(bytes: words, nodeIndex2ID: chars)
                try writeLoudstxt3ShardsAligned(
                    entries: group,
                    id: id,
                    louds: louds,
                    char2UInt8: char2UInt8,
                    directoryURL: directoryURL,
                    shardShift: effectiveShardShift,
                    entriesPerShard: effectiveEntriesPerShard,
                    localMask: effectiveLocalMask
                )
            }
        } else {
            let id = baseName
            let loudsURL = directoryURL.appendingPathComponent("\(id).louds")
            let charsURL = directoryURL.appendingPathComponent("\(id).loudschars2")
            let (bits, chars) = buildLOUDS(entries: entries, char2UInt8: char2UInt8)
            try writeLOUDS(bits: bits, nodes2Characters: chars, loudsURL: loudsURL, loudsChars2URL: charsURL)
            // loudstxt3 shards aligned to LOUDS node indices
            let words = makeLOUDSWords(bits: bits)
            let louds = LOUDS(bytes: words, nodeIndex2ID: chars)
            try writeLoudstxt3ShardsAligned(
                entries: entries,
                id: id,
                louds: louds,
                char2UInt8: char2UInt8,
                directoryURL: directoryURL,
                shardShift: effectiveShardShift,
                entriesPerShard: effectiveEntriesPerShard,
                localMask: effectiveLocalMask
            )
        }
    }

    /// Convenience overload: load `charID.chid`-style mapping from a file.
    public static func exportDictionary(
        entries: [DicdataElement],
        to directoryURL: URL,
        baseName: String,
        shardByFirstCharacter: Bool,
        charIDFileURL: URL,
        shardShift: Int? = nil
    ) throws {
        let string = try String(contentsOf: charIDFileURL, encoding: .utf8)
        let map = Dictionary(uniqueKeysWithValues: string.enumerated().map { ($0.element, UInt8($0.offset)) })
        try exportDictionary(entries: entries, to: directoryURL, baseName: baseName, shardByFirstCharacter: shardByFirstCharacter, char2UInt8: map, shardShift: shardShift)
    }

    /// Pack LOUDS bit sequence (as Bool) into Data of UInt64 (big-endian bit order per existing format).
    static func makeLOUDSData(bits: [Bool]) -> Data {
        let unit = 64
        let (q, r) = bits.count.quotientAndRemainder(dividingBy: unit)
        let paddedCount = r == 0 ? bits.count : (q + 1) * unit
        var data = Data(capacity: (paddedCount / unit) * MemoryLayout<UInt64>.size)
        var value: UInt64 = 0
        var idxInUnit = 0
        for b in bits {
            if b {
                value |= (1 << (unit - idxInUnit - 1))
            }
            idxInUnit += 1
            if idxInUnit == unit {
                var v = value
                data.append(Data(bytes: &v, count: MemoryLayout<UInt64>.size))
                value = 0
                idxInUnit = 0
            }
        }
        if idxInUnit != 0 {
            // pad remaining with 1 (as existing writers do)
            while idxInUnit < unit {
                value |= (1 << (unit - idxInUnit - 1))
                idxInUnit += 1
            }
            var v = value
            data.append(Data(bytes: &v, count: MemoryLayout<UInt64>.size))
        }
        return data
    }

    /// Build LOUDS 64-bit words (little-endian on current platforms) from bit sequence.
    /// This mirrors `makeLOUDSData` but returns words for in-memory LOUDS construction.
    static func makeLOUDSWords(bits: [Bool]) -> [UInt64] {
        let unit = 64
        let (q, r) = bits.count.quotientAndRemainder(dividingBy: unit)
        let paddedCount = r == 0 ? bits.count : (q + 1) * unit
        var words: [UInt64] = []
        words.reserveCapacity(paddedCount / unit)
        var value: UInt64 = 0
        var idxInUnit = 0
        for b in bits {
            if b {
                value |= (1 << (unit - idxInUnit - 1))
            }
            idxInUnit += 1
            if idxInUnit == unit {
                words.append(value)
                value = 0
                idxInUnit = 0
            }
        }
        if idxInUnit != 0 {
            while idxInUnit < unit {
                value |= (1 << (unit - idxInUnit - 1))
                idxInUnit += 1
            }
            words.append(value)
        }
        return words
    }

    /// Build loudschars2 binary from node-to-character table.
    static func makeLoudsChars2Data(nodes2Characters: [UInt8]) -> Data {
        Data(nodes2Characters)
    }

    /// Escape a shard identifier string into filesystem-safe fixed-width hex chunks.
    /// - Encoding: UTF-16 code units represented as 4-hex uppercase, joined by underscores, wrapped in brackets.
    ///   Example: "あ" -> "[3042]", "AB" -> "[0041_0042]", "🇯🇵" -> "[D83C_DDEF_D83C_DDF5]"
    ///   - BMP scalars: single 4-hex chunk
    ///   - Non-BMP scalars: surrogate pair (two chunks)
    /// - Special cases: "user", "memory", and "user_shortcuts" are returned as-is
    static func escapedIdentifier(_ inputIdentifier: String) -> String {
        switch inputIdentifier {
        case "user", "memory", "user_shortcuts":
            return inputIdentifier
        default:
            break
        }
        var chunks: [String] = []
        chunks.reserveCapacity(inputIdentifier.utf16.count)
        for scalar in inputIdentifier.unicodeScalars {
            if scalar.value <= 0xFFFF {
                chunks.append(String(format: "%04X", scalar.value))
            } else {
                let s = String(scalar)
                for cu in s.utf16 {
                    chunks.append(String(format: "%04X", cu))
                }
            }
        }
        return "[" + chunks.joined(separator: "_") + "]"
    }

    /// High-level: write LOUDS and loudschars2 files atomically to given URLs.
    static func writeLOUDS(bits: [Bool], nodes2Characters: [UInt8], loudsURL: URL, loudsChars2URL: URL) throws {
        let loudsData = makeLOUDSData(bits: bits)
        let charsData = makeLoudsChars2Data(nodes2Characters: nodes2Characters)
        try loudsData.write(to: loudsURL)
        try charsData.write(to: loudsChars2URL)
    }

    private static func writeLoudstxt3ShardsAligned(entries: [DicdataElement], id: String, louds: LOUDS, char2UInt8: [Character: UInt8], directoryURL: URL, shardShift: Int, entriesPerShard: Int, localMask: Int) throws {
        // Group entries by ruby, compute their LOUDS node index, and shard by (index >> shardShift)
        let grouped = Dictionary(grouping: entries, by: { $0.ruby })
        var shards: [Int: [(local: Int, ruby: String, rows: [Loudstxt3Builder.Row])]] = [:]
        for (ruby, elems) in grouped {
            // Map ruby to char IDs
            var ids: [UInt8] = []
            ids.reserveCapacity(ruby.count)
            var ok = true
            for ch in ruby {
                guard let v = char2UInt8[ch] else {
                    ok = false
                    break
                }
                ids.append(v)
            }
            guard ok, let nodeIndex = louds.searchNodeIndex(chars: ids) else {
                continue
            }
            let shard = nodeIndex >> shardShift
            let local = nodeIndex & localMask
            let rows = elems.map { e in
                Loudstxt3Builder.Row(word: e.word, lcid: e.lcid, rcid: e.rcid, mid: e.mid, score: Float32(e.value()))
            }
            shards[shard, default: []].append((local: local, ruby: ruby, rows: rows))
        }
        for (shard, items) in shards.sorted(by: { $0.key < $1.key }) {
            let url = directoryURL.appendingPathComponent("\(id)\(shard).loudstxt3")
            try Loudstxt3Builder.writeAligned(items: items, to: url, entriesPerShard: entriesPerShard)
        }
    }

    private static func buildLOUDS(entries: [DicdataElement], char2UInt8: [Character: UInt8]) -> (bits: [Bool], nodes2Characters: [UInt8]) {
        struct Node {
            var children: OrderedDictionary<UInt8, Node> = [:]
        }

        var root = Node()
        func keyToChars(_ key: some StringProtocol) -> [UInt8]? {
            var chars: [UInt8] = []
            chars.reserveCapacity(key.count)
            for ch in key {
                guard let id = char2UInt8[ch] else {
                    return nil
                }
                chars.append(id)
            }
            return chars
        }
        for e in entries {
            guard let chars = keyToChars(e.ruby) else {
                continue
            }
            // walk & insert
            func insert(_ node: Node, _ path: ArraySlice<UInt8>) -> Node {
                var node = node
                if let c = path.first {
                    node.children[c] = insert(node.children[c] ?? Node(), path.dropFirst())
                }
                return node
            }
            root = insert(root, ArraySlice(chars))
        }
        var nodes2Characters: [UInt8] = [0x0, 0x0]
        var bits: [Bool] = [true, false]
        var current: [(UInt8, Node)] = root.children.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        bits += [Bool](repeating: true, count: current.count) + [false]
        while !current.isEmpty {
            var next: [(UInt8, Node)] = []
            for (char, node) in current {
                nodes2Characters.append(char)
                let children = node.children.sorted { $0.key < $1.key }
                bits += [Bool](repeating: true, count: children.count) + [false]
                next.append(contentsOf: children.map { ($0.key, $0.value) })
            }
            current = next
        }
        return (bits, nodes2Characters)
    }
}

enum Loudstxt3Builder {
    struct Row: Sendable {
        public init(word: String, lcid: Int, rcid: Int, mid: Int, score: Float32) {
            self.word = word
            self.lcid = lcid
            self.rcid = rcid
            self.mid = mid
            self.score = score
        }
        public var word: String
        public var lcid: Int
        public var rcid: Int
        public var mid: Int
        public var score: Float32
    }

    /// Make loudstxt3 binary from grouped entries per ruby key.
    /// Each element represents one node (one ruby string) and its rows.
    static func makeBinary(entries: [(ruby: String, rows: [Row])]) -> Data {
        let lc = entries.count
        var body = Data()
        body.reserveCapacity(lc * 64)
        // Build per-entry payloads
        var payloads: [Data] = []
        payloads.reserveCapacity(lc)
        for entry in entries {
            var d = Data()
            var count = UInt16(entry.rows.count)
            d.append(Data(bytes: &count, count: MemoryLayout<UInt16>.size))
            // numeric rows
            for row in entry.rows {
                var lcid = UInt16(row.lcid)
                var rcid = UInt16(row.rcid)
                var mid = UInt16(row.mid)
                var score = Float32(row.score)
                d.append(Data(bytes: &lcid, count: MemoryLayout<UInt16>.size))
                d.append(Data(bytes: &rcid, count: MemoryLayout<UInt16>.size))
                d.append(Data(bytes: &mid, count: MemoryLayout<UInt16>.size))
                d.append(Data(bytes: &score, count: MemoryLayout<Float32>.size))
            }
            // text area: ruby + words (empty string when equals ruby), separated by tab
            let text = ([entry.ruby] + entry.rows.map { $0.word == entry.ruby ? "" : $0.word }).joined(separator: "\t")
            d.append(text.data(using: .utf8, allowLossyConversion: false)!)
            payloads.append(d)
        }
        // header count (UInt16)
        var count16 = UInt16(lc)
        var result = Data()
        result.append(Data(bytes: &count16, count: MemoryLayout<UInt16>.size))
        // header offsets (UInt32), cumulative — include all lc offsets
        var offset: UInt32 = 2 + UInt32(lc) * UInt32(MemoryLayout<UInt32>.size)
        for i in 0 ..< lc {
            result.append(Data(bytes: &offset, count: MemoryLayout<UInt32>.size))
            offset &+= UInt32(payloads[i].count)
        }
        // body
        for p in payloads { result.append(p) }
        return result
    }

    /// High-level: write a loudstxt3 file with entriesPerShard header slots aligned to LOUDS local indices.
    /// - Parameter items: list of (local index, ruby, rows) for this shard.
    static func writeAligned(items: [(local: Int, ruby: String, rows: [Row])], to url: URL, entriesPerShard: Int) throws {
        // Initialize each slot with a zero-count (2 bytes) payload so empty slots are valid to parse.
        var payloads: [Data] = Array(repeating: {
            var z: UInt16 = 0
            return Data(bytes: &z, count: MemoryLayout<UInt16>.size)
        }(), count: entriesPerShard)
        for item in items {
            guard (0 ..< entriesPerShard).contains(item.local) else {
                continue
            }
            var d = Data()
            var count = UInt16(item.rows.count)
            d.append(Data(bytes: &count, count: MemoryLayout<UInt16>.size))
            for row in item.rows {
                var lcid = UInt16(row.lcid)
                var rcid = UInt16(row.rcid)
                var mid = UInt16(row.mid)
                var score = Float32(row.score)
                d.append(Data(bytes: &lcid, count: MemoryLayout<UInt16>.size))
                d.append(Data(bytes: &rcid, count: MemoryLayout<UInt16>.size))
                d.append(Data(bytes: &mid, count: MemoryLayout<UInt16>.size))
                d.append(Data(bytes: &score, count: MemoryLayout<Float32>.size))
            }
            let text = ([item.ruby] + item.rows.map { $0.word == item.ruby ? "" : $0.word }).joined(separator: "\t")
            d.append(text.data(using: .utf8, allowLossyConversion: false)!)
            payloads[item.local] = d
        }
        // Build header
        var result = Data()
        var count16 = UInt16(entriesPerShard)
        result.append(Data(bytes: &count16, count: MemoryLayout<UInt16>.size))
        // write offsets for all slots
        var offset: UInt32 = 2 + UInt32(entriesPerShard) * UInt32(MemoryLayout<UInt32>.size)
        for i in 0 ..< entriesPerShard {
            result.append(Data(bytes: &offset, count: MemoryLayout<UInt32>.size))
            offset &+= UInt32(payloads[i].count)
        }
        // Body
        for p in payloads { result.append(p) }
        try result.write(to: url, options: .atomic)
    }

    /// Backward-compatible wrapper for default entriesPerShard.
    static func writeAligned2048(items: [(local: Int, ruby: String, rows: [Row])], to url: URL) throws {
        try writeAligned(items: items, to: url, entriesPerShard: DictionaryBuilder.entriesPerShard)
    }

    /// High-level: write sequential shards of loudstxt3 by fixed group size.
    /// Splits the given entries into contiguous chunks and writes each chunk as one loudstxt3 file.
    /// - Returns: number of files written
    static func writeSequentialShards(entries: [(ruby: String, rows: [Row])], split: Int, urlProvider: (Int) -> URL) throws -> Int {
        guard split > 0 else {
            return 0
        }
        let total = entries.count
        if total == 0 {
            return 0
        }
        var fileIndex = 0
        var start = 0
        while start < total {
            let end = min(start + split, total)
            let data = makeBinary(entries: Array(entries[start..<end]))
            try data.write(to: urlProvider(fileIndex), options: .atomic)
            fileIndex += 1
            start = end
        }
        return fileIndex
    }
}
