import ArgumentParser
import Foundation
import OrderedCollections

extension Subcommands.Dict {
    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "build", abstract: "Build louds dictionary files and cost files from source files.")
        private static let targetChars = [
            "￣", "‐", "―", "〜", "・", "、", "…", "‥", "。", "‘", "’", "“", "”", "〈", "〉", "《", "》", "「", "」", "『", "』", "【", "】", "〔", "〕", "‖", "*", "′", "〃", "※", "´", "¨", "゛", "゜", "←", "→", "↑", "↓", "─", "■", "□", "▲", "△", "▼", "▽", "◆", "◇", "○", "◎", "●", "★", "☆", "々", "ゝ", "ヽ", "ゞ", "ヾ", "ー", "〇", "ァ", "ア", "ィ", "イ", "ゥ", "ウ", "ヴ", "ェ", "エ", "ォ", "オ", "ヵ", "カ", "ガ", "キ", "ギ", "ク", "グ", "ヶ", "ケ", "ゲ", "コ", "ゴ", "サ", "ザ", "シ", "ジ", "〆", "ス", "ズ", "セ", "ゼ", "ソ", "ゾ", "タ", "ダ", "チ", "ヂ", "ッ", "ツ", "ヅ", "テ", "デ", "ト", "ド", "ナ", "ニ", "ヌ", "ネ", "ノ", "ハ", "バ", "パ", "ヒ", "ビ", "ピ", "フ", "ブ", "プ", "ヘ", "ベ", "ペ", "ホ", "ボ", "ポ", "マ", "ミ", "ム", "メ", "モ", "ヤ", "ユ", "ョ", "ヨ", "ラ", "リ", "ル", "レ", "ロ", "ヮ", "ワ", "ヰ", "ヱ", "ヲ", "ン", "仝", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "！", "？", "(", ")", "#", "%", "&", "^", "_", "'", "\"", "=", "ㇻ"
        ]

        @Option(name: [.customLong("work_dir")], help: "Work directory that contains (1) `c/` which contains csv file named 'cid.csv' for each cid, and mm.csv which is a csv file of mid-mid bigram matrix; (2) `worddict/`, which contains tsv formatted file of the dictionary; (3) mm.csv which is a csv file of mid-mid bigram matrix.")
        var workingDirectory: String = ""

        @Flag(name: [.customShort("k"), .customLong("gitkeep")], help: "Adds .gitkeep file.")
        var addGitKeepFile = false

        @Flag(name: [.customShort("c"), .customLong("clean")], help: "Cleans target directory.")
        var cleanTargetDirectory = false

        @Option(name: [.customShort("s"), .customLong("split")], help: "A loudstxt3 file will contain this number of entries.")
        var loudsTxtFileSplitCount: Int = 2048

        @Flag(name: [.customShort("v"), .customLong("verbose")], help: "Verbose logs.")
        var verbose = false
    }
}

extension Subcommands.Dict.Build {
    mutating func run() throws {
        let sourceDirectoryURL = URL(fileURLWithPath: self.workingDirectory, isDirectory: true).appending(path: "worddict", directoryHint: .isDirectory)
        let targetDirectoryURL = URL(fileURLWithPath: self.workingDirectory, isDirectory: true).appending(path: "louds", directoryHint: .isDirectory)
        if self.cleanTargetDirectory {
            print("Cleans target directory \(targetDirectoryURL.path)...")
            let fileURLs = try FileManager.default.contentsOfDirectory(at: targetDirectoryURL, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                try FileManager.default.removeItem(at: fileURL)
            }
            print("Done!")
        }
        let loudsBuilder = LOUDSBuilder(sourceDirectory: sourceDirectoryURL, targetDirectory: targetDirectoryURL, txtFileSplit: loudsTxtFileSplitCount)

        print("Generates LOUDS files into \(targetDirectoryURL.path)...")
        for target in Self.targetChars {
            do {
                try loudsBuilder.process(target, verbose: verbose)
            } catch {
                print("Error on \(target)")
                throw error
            }
        }
        print("Add charID.chid file...")
        try LOUDSBuilder.writeCharID(targetDirectory: targetDirectoryURL)
        if addGitKeepFile {
            print("Adds .gitkeep file into \(targetDirectoryURL.path)...")
            try LOUDSBuilder.writeGitKeep(targetDirectory: targetDirectoryURL)
        }

        print("Done!")

        let workDirectoryURL = URL(fileURLWithPath: self.workingDirectory, isDirectory: true)
        if cleanTargetDirectory {
            let cbDirectoryURL = workDirectoryURL.appendingPathComponent("cb", isDirectory: true)
            print("Cleans target directory \(cbDirectoryURL.path)...")
            let fileURLs = try FileManager.default.contentsOfDirectory(at: cbDirectoryURL, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                try FileManager.default.removeItem(at: fileURL)
            }
            let mmBinaryFileURL = workDirectoryURL.appendingPathComponent("mm.binary", isDirectory: false)
            try FileManager.default.removeItem(at: mmBinaryFileURL)
            print("Done!")
        }
        let builder = CostBuilder(workDirectory: workDirectoryURL)
        print("Generates binary files into \(workDirectoryURL.path)...")
        try builder.build()
        if self.addGitKeepFile {
            print("Adds .gitkeep file into \(workDirectoryURL.path)...")
            try builder.writeGitKeep()
        }
        print("Done!")
    }
}

struct CostBuilder {
    struct Int2Float {
        let int: Int32
        let float: Float
    }

    let workDirectory: URL

    func loadBinaryMM(path: String) -> [Float] {
        do {
            let binaryData = try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])

            let ui64array = binaryData.withUnsafeBytes {pointer -> [Float] in
                Array(
                    UnsafeBufferPointer(
                        start: pointer.baseAddress!.assumingMemoryBound(to: Float.self),
                        count: pointer.count / MemoryLayout<Float>.size
                    )
                )
            }
            return ui64array
        } catch {
            print("Failed to read the file.", error)
            return []
        }
    }

    func loadBinaryIF(path: String) -> [(Int16, Float)] {
        do {
            let binaryData = try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])

            let ui64array = binaryData.withUnsafeBytes {pointer -> [(Int16, Float)] in
                Array(
                    UnsafeBufferPointer(
                        start: pointer.baseAddress!.assumingMemoryBound(to: (Int16, Float).self),
                        count: pointer.count / MemoryLayout<(Int16, Float)>.size
                    )
                )
            }
            return ui64array
        } catch {
            print("Failed to read the file.", error)
            return []
        }
    }

    func build_mm() throws {
        let sourceURL = self.workDirectory.appendingPathComponent("mm.csv", isDirectory: false)
        let targetURL = self.workDirectory.appendingPathComponent("mm.binary", isDirectory: false)

        let string = try String(contentsOf: sourceURL, encoding: .utf8)
        let floats = string.components(separatedBy: .newlines).map {
            $0.components(separatedBy: ",").map {Float($0) ?? -30}
        }
        var flatten: [Float] = floats.flatMap {$0}
        let data = Data(bytes: &flatten, count: flatten.count * MemoryLayout<Float>.size)
        try data.write(to: targetURL, options: .atomic)
    }

    func build_if_c(_ cid: Int) throws {
        let sourceURL = self.workDirectory.appendingPathComponent("c", isDirectory: true).appendingPathComponent("\(cid).csv", isDirectory: false)
        let targetURL = self.workDirectory.appendingPathComponent("cb", isDirectory: true).appendingPathComponent("\(cid).binary", isDirectory: false)

        let string = try String(contentsOf: sourceURL, encoding: .utf8)
        let list: [Int2Float] = string.components(separatedBy: .newlines).map {(string: String) in
            let components = string.components(separatedBy: ",")
            return Int2Float(int: Int32(components[0]) ?? -1, float: Float(components[1]) ?? -30.0)
        }
        let size = MemoryLayout<Int2Float>.size
        let data = Array(Data(bytes: list, count: list.count * size))
        try Data(data).write(to: targetURL, options: .atomic)
    }

    func build_if_m(_ mid: Int) throws {
        let sourceURL = self.workDirectory.appendingPathComponent("m", isDirectory: true).appendingPathComponent("\(mid).csv", isDirectory: false)
        let targetURL = self.workDirectory.appendingPathComponent("mb", isDirectory: true).appendingPathComponent("\(mid).binary", isDirectory: false)

        let string = try String(contentsOf: sourceURL, encoding: .utf8)
        let list: [Int2Float] = string.components(separatedBy: .newlines).map {(string: String) in
            let components = string.components(separatedBy: ",")
            return Int2Float(int: Int32(components[0]) ?? -1, float: Float(components[1]) ?? -30.0)
        }
        let size = MemoryLayout<Int2Float>.size
        let data = Array(Data(bytes: list, count: list.count * size))
        try Data(data).write(to: targetURL, options: .atomic)
    }

    func writeGitKeep() throws {
        let fileURL = self.workDirectory.appendingPathComponent("c", isDirectory: true).appendingPathComponent(".gitkeep", isDirectory: false)
        try "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func build() throws {
        for i in 0...1318 {
            try build_if_c(i)
        }
        try build_mm()
    }

}

struct LOUDSBuilder {
    let sourceDirectory: URL
    let txtFileSplit: Int
    let targetDirectory: URL
    init(sourceDirectory: URL, targetDirectory: URL, txtFileSplit: Int) {
        self.sourceDirectory = sourceDirectory
        self.targetDirectory = targetDirectory
        self.txtFileSplit = txtFileSplit
    }

    private func BoolToUInt64(_ bools: [Bool]) -> [UInt64] {
        let unit = 64
        let value = bools.count.quotientAndRemainder(dividingBy: unit)
        let _bools = bools + [Bool].init(repeating: true, count: (unit - value.remainder) % unit)
        var result = [UInt64]()
        for i in 0...value.quotient {
            var value: UInt64 = 0
            for j in 0..<unit {
                value += (_bools[i * unit + j] ? 1 : 0) << (unit - j - 1)
            }
            result.append(value)
        }
        return result
    }

    struct DataBlock {
        var count: Int {
            data.count
        }
        var ruby: String
        var data: [(word: String, lcid: Int, rcid: Int, mid: Int, score: Float)]

        init(entries: [String]) {
            self.ruby = ""
            self.data = []

            for entry in entries {
                let items = entry.utf8.split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false).map {String($0)!}
                assert(items.count == 6)
                let ruby = String(items[0])
                let word = items[1].isEmpty ? self.ruby : String(items[1])
                let lcid = Int(items[2]) ?? .zero
                let rcid = Int(items[3]) ?? lcid
                let mid = Int(items[4]) ?? .zero
                let score = Float(items[5]) ?? -30.0

                if self.ruby.isEmpty {
                    self.ruby = ruby
                } else {
                    assert(self.ruby == ruby)
                }
                self.data.append((word, lcid, rcid, mid, score))
            }
        }

        func makeLoudstxt3Entry() -> Data {
            var data = Data()
            assert(0 <= count && count <= UInt16.max)
            // エントリのカウントを2byteでエンコード
            var count = UInt16(self.count)
            data.append(contentsOf: Data(bytes: &count, count: MemoryLayout<UInt16>.size))

            // 数値データ部をエンコード
            // 10byteが1つのエントリに対応するので、10*count byte
            for (_, lcid, rcid, mid, score) in self.data {
                assert(0 <= lcid && lcid <= UInt16.max)
                assert(0 <= rcid && rcid <= UInt16.max)
                assert(0 <= mid && mid <= UInt16.max)
                var lcid = UInt16(lcid)
                var rcid = UInt16(rcid)
                var mid = UInt16(mid)
                data.append(contentsOf: Data(bytes: &lcid, count: MemoryLayout<UInt16>.size))
                data.append(contentsOf: Data(bytes: &rcid, count: MemoryLayout<UInt16>.size))
                data.append(contentsOf: Data(bytes: &mid, count: MemoryLayout<UInt16>.size))
                var score = Float32(score)
                data.append(contentsOf: Data(bytes: &score, count: MemoryLayout<Float32>.size))
            }

            // wordをエンコード
            // 最先頭の要素はrubyになる
            let text = ([self.ruby] + self.data.map { $0.word == self.ruby ? "" : $0.word }).joined(separator: "\t")
            data.append(contentsOf: text.data(using: .utf8, allowLossyConversion: false)!)
            return data
        }
    }

    func make_loudstxt3(lines: [DataBlock]) -> Data {
        let lc = lines.count    // データ数
        let count = Data(bytes: [UInt16(lc)], count: 2) // データ数をUInt16でマップ

        let data = lines.map { $0.makeLoudstxt3Entry() }
        let body = data.reduce(Data(), +)   // データ

        let header_endIndex: UInt32 = 2 + UInt32(lc) * UInt32(MemoryLayout<UInt32>.size)
        let headerArray = data.dropLast().reduce(into: [header_endIndex]) {array, value in // ヘッダの作成
            array.append(array.last! + UInt32(value.count))
        }

        let header = Data(bytes: headerArray, count: MemoryLayout<UInt32>.size * headerArray.count)
        let binary = count + header + body

        return binary
    }

    func process(_ inputIdentifier: String, verbose: Bool) throws {
        if verbose {
            print("Processing \(inputIdentifier)...")
        }
        let csvLines: [String]
        let trieroot = TrieNode<Character, Int>()
        // Warning: この行に変更を加える場合、合わせてAzooKeyKanaKanjiConverterにも変更を加えること。
        let outputIdentifier = [
            #"\n"#: "[0A]",
            #" "#: "[20]",
            #"""#: "[22]",
            #"'"#: "[27]",
            #"*"#: "[2A]",
            #"+"#: "[2B]",
            #"."#: "[2E]",
            #"/"#: "[2F]",
            #":"#: "[3A]",
            #"<"#: "[3C]",
            #">"#: "[3E]",
            #"\"#: "[5C]",
            #"|"#: "[7C]"
        ][inputIdentifier, default: inputIdentifier]
        let sourceURL = self.sourceDirectory.appendingPathComponent("\(inputIdentifier).tsv", isDirectory: false)
        let loudsURL = self.targetDirectory.appendingPathComponent("\(outputIdentifier).louds", isDirectory: false)
        let loudscharsURL = self.targetDirectory.appendingPathComponent("\(outputIdentifier).loudschars2", isDirectory: false)
        let loudstxtURL: (String) -> URL = {self.targetDirectory.appendingPathComponent("\(outputIdentifier)\($0).loudstxt3", isDirectory: false)}

        do {
            let tsvString = try String(contentsOf: sourceURL, encoding: .utf8)
            csvLines = tsvString.components(separatedBy: .newlines)
            let csvData = csvLines.map {$0.utf8.split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false)}
            csvData.indices.forEach {index in
                let ruby = String(csvData[index][0])!
                guard Self.skipCharacters.intersection(ruby).isEmpty else {
                    return
                }
                trieroot.insertValue(for: ruby, value: index)
            }
        } catch let error as NSError {
            if error.code == 260 {
                print("ファイル「\(inputIdentifier).tsv」が存在しないので、スキップします")
                return
            } else {
                throw error
            }
        }

        var currentID = 0
        var nodes2Characters: [Character] = ["\0", "\0"]
        var data: [DataBlock] = [.init(entries: []), .init(entries: [])]
        var bits: [Bool] = [true, false]
        trieroot.id = currentID
        currentID += 1
        var currentNodes: [(Character, TrieNode<Character, Int>)] = trieroot.children.map {($0.key, $0.value)}
        bits += [Bool].init(repeating: true, count: trieroot.children.count) + [false]
        while !currentNodes.isEmpty {
            currentNodes.forEach {char, trie in
                trie.id = currentID
                nodes2Characters.append(char)
                // loudstxt3
                let loudstxt3Entry: DataBlock = DataBlock(entries: trie.value.map {csvLines[$0]})
                data.append(loudstxt3Entry)
                bits += [Bool].init(repeating: true, count: trie.children.count) + [false]
                currentID += 1
            }
            currentNodes = currentNodes.flatMap {$0.1.children.map {($0.key, $0.value)}}
        }
        if bits.count == 2 {
            print("No data found for \(inputIdentifier)")
            return
        }

        let bytes = BoolToUInt64(bits)

        do {
            let binary = Data(bytes: bytes, count: bytes.count * 8)
            try binary.write(to: loudsURL)
        }
        do {
            let uint8s = nodes2Characters.map {Self.getID(from: $0)}
            let binary = Data(bytes: uint8s, count: uint8s.count)
            try binary.write(to: loudscharsURL)
        }
        do {
            let count = (data.count) / txtFileSplit
            let indiceses: [Range<Int>] = (0...count).map {
                let start = $0 * txtFileSplit
                let _end = ($0 + 1) * txtFileSplit
                let end = data.count < _end ? data.count : _end
                return start..<end
            }

            for indices in indiceses {
                let start = indices.startIndex / txtFileSplit
                let binary = make_loudstxt3(lines: Array(data[indices]))
                try binary.write(to: loudstxtURL("\(start)"), options: .atomic)
            }
        }
    }

}

class TrieNode<Key: Hashable, Value: Hashable> {
    var value: OrderedSet<Value>
    var children: OrderedDictionary<Key, TrieNode<Key, Value>>
    var id = -1

    init(value: [Value] = [], children: OrderedDictionary<Key, TrieNode<Key, Value>> = [:]) {
        self.value = OrderedSet(value)
        self.children = children
    }

    func insertValue(for keys: [Key], value: Value) {
        var current: TrieNode<Key, Value> = self
        keys.forEach { key in
            if let next = current.children[key] {
                current = next
            } else {
                let newNode = TrieNode<Key, Value>()
                current.children[key] = newNode
                current = newNode
            }
        }
        current.value.append(value)
    }
}

extension TrieNode where Key == Character {
    func insertValue<S: StringProtocol>(for keys: S, value: Value) {
        self.insertValue(for: keys.map {$0}, value: value)
    }
}

extension LOUDSBuilder {
    static let char2UInt8 = [Character: UInt8](
        uniqueKeysWithValues: ["\0", "　", "￣", "‐", "―", "〜", "・", "、", "…", "‥", "。", "‘", "’", "“", "”", "〈", "〉", "《", "》", "「", "」", "『", "』", "【", "】", "〔", "〕", "‖", "*", "′", "〃", "※", "´", "¨", "゛", "゜", "←", "→", "↑", "↓", "─", "■", "□", "▲", "△", "▼", "▽", "◆", "◇", "○", "◎", "●", "★", "☆", "々", "ゝ", "ヽ", "ゞ", "ヾ", "ー", "〇", "Q", "ァ", "ア", "ィ", "イ", "ゥ", "ウ", "ヴ", "ェ", "エ", "ォ", "オ", "ヵ", "カ", "ガ", "キ", "ギ", "ク", "グ", "ヶ", "ケ", "ゲ", "コ", "ゴ", "サ", "ザ", "シ", "ジ", "〆", "ス", "ズ", "セ", "ゼ", "ソ", "ゾ", "タ", "ダ", "チ", "ヂ", "ッ", "ツ", "ヅ", "テ", "デ", "ト", "ド", "ナ", "ニ", "ヌ", "ネ", "ノ", "ハ", "バ", "パ", "ヒ", "ビ", "ピ", "フ", "ブ", "プ", "ヘ", "ベ", "ペ", "ホ", "ボ", "ポ", "マ", "ミ", "ム", "メ", "モ", "ャ", "ヤ", "ュ", "ユ", "ョ", "ヨ", "ラ", "リ", "ル", "レ", "ロ", "ヮ", "ワ", "ヰ", "ヱ", "ヲ", "ン", "仝", "&", "A", "！", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "？", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "^", "_", "=", "ㇻ", "(", ")", "#", "%", "'", "\"", "+", "-", "ㇼ"]
            .enumerated()
            .map {
                (Character($0.element), UInt8($0.offset))
            }
    )

    /// これらの文字を含む単語はスキップする
    static let skipCharacters: Set<Character> = [
        "ヷ", "ヸ", "!", "　", "\0"
    ]

    static func getID(from char: Character) -> UInt8 {
        if let id = Self.char2UInt8[char] {
            return id
        }
        fatalError("Unknown target character \(char) \(char.unicodeScalars.map {$0.value}). Consider adding this character to `skipCharacters`")
    }

    static func writeCharID(targetDirectory: URL) throws {
        let url = targetDirectory.appendingPathComponent("charID.chid", isDirectory: false)
        let chars = Self.char2UInt8.sorted {$0.value < $1.value}.map {$0.key}
        try chars.map {String($0)}.joined().write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeGitKeep(targetDirectory: URL) throws {
        let url = targetDirectory.appendingPathComponent(".gitkeep", isDirectory: false)
        try "".write(to: url, atomically: true, encoding: .utf8)
    }
}
