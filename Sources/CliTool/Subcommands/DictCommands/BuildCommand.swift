import ArgumentParser
import Foundation
import KanaKanjiConverterModule
import OrderedCollections

extension Subcommands.Dict {
    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "build", abstract: "Build louds dictionary files and cost files from source files.")
        private static let romanChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz").map(String.init)
        // 取り込み対象をcharID表から導き、対応文字の追加時にTSVを読み落とさないようにする。
        private static let targetChars: [String] = Self.char2UInt8
            .filter { !Self.skipCharacters.contains($0.key) }
            .sorted { $0.value < $1.value }
            .map { String($0.key) }

        @Option(name: [.customLong("work_dir")], help: "Work directory that contains (1) `c/` which contains csv file named 'cid.csv' for each cid, and mm.csv which is a csv file of mid-mid bigram matrix; (2) `worddict/`, which contains tsv formatted file of the dictionary; (3) mm.csv which is a csv file of mid-mid bigram matrix.")
        var workingDirectory: String = ""

        @Flag(name: [.customShort("k"), .customLong("gitkeep")], help: "Adds .gitkeep file.")
        var addGitKeepFile = false

        @Flag(name: [.customShort("c"), .customLong("clean")], help: "Cleans target directory.")
        var cleanTargetDirectory = false

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
        print("Generates LOUDS files into \(targetDirectoryURL.path) via unified API...")
        var allEntries: [DicdataElement] = []
        for target in Self.targetChars {
            // ASCII英字は大小文字を区別しないファイルシステムでも衝突しない名前を使う。
            let filename = Self.romanChars.contains(target) ? DictionaryBuilder.escapedIdentifier(target) : target
            let sourceURL = sourceDirectoryURL.appendingPathComponent("\(filename).tsv", isDirectory: false)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                continue
            }
            let tsvString = try String(contentsOf: sourceURL, encoding: .utf8)
            let lines = tsvString.components(separatedBy: .newlines)
            for line in lines where !line.isEmpty {
                let items = line.utf8.split(separator: UInt8(ascii: "\t"), omittingEmptySubsequences: false).map {String($0)!}
                if items.count != 6 {
                    continue
                }
                let ruby = String(items[0])
                guard Self.skipCharacters.intersection(ruby).isEmpty else {
                    continue
                }
                let word = items[1].isEmpty ? ruby : String(items[1])
                let lcid = Int(items[2]) ?? .zero
                let rcid = Int(items[3]) ?? lcid
                let mid = Int(items[4]) ?? .zero
                let score = Float(items[5]) ?? -30.0
                allEntries.append(DicdataElement(word: word, ruby: ruby, lcid: lcid, rcid: rcid, mid: mid, value: PValue(score)))
            }
        }
        try DictionaryBuilder.exportDictionary(
            entries: allEntries,
            to: targetDirectoryURL,
            baseName: "",
            shardByFirstCharacter: true,
            char2UInt8: Self.char2UInt8
        )
        print("Add charID.chid file...")
        try Self.writeCharID(targetDirectory: targetDirectoryURL)
        if addGitKeepFile {
            print("Adds .gitkeep file into \(targetDirectoryURL.path)...")
            try Self.writeGitKeep(targetDirectory: targetDirectoryURL)
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

            return binaryData.withUnsafeBytes {pointer -> [Float] in
                Array(
                    UnsafeBufferPointer(
                        start: pointer.baseAddress!.assumingMemoryBound(to: Float.self),
                        count: pointer.count / MemoryLayout<Float>.size
                    )
                )
            }
        } catch {
            print("Failed to read the file.", error)
            return []
        }
    }

    func loadBinaryIF(path: String) -> [(Int16, Float)] {
        do {
            let binaryData = try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])

            return binaryData.withUnsafeBytes {pointer -> [(Int16, Float)] in
                Array(
                    UnsafeBufferPointer(
                        start: pointer.baseAddress!.assumingMemoryBound(to: (Int16, Float).self),
                        count: pointer.count / MemoryLayout<(Int16, Float)>.size
                    )
                )
            }
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

extension Subcommands.Dict.Build {
    static let char2UInt8 = [Character: UInt8](
        uniqueKeysWithValues: ["\0", "　", "￣", "‐", "―", "〜", "・", "、", "…", "‥", "。", "‘", "’", "“", "”", "〈", "〉", "《", "》", "「", "」", "『", "』", "【", "】", "〔", "〕", "‖", "*", "′", "〃", "※", "´", "¨", "゛", "゜", "←", "→", "↑", "↓", "─", "■", "□", "▲", "△", "▼", "▽", "◆", "◇", "○", "◎", "●", "★", "☆", "々", "ゝ", "ヽ", "ゞ", "ヾ", "ー", "〇", "Q", "ァ", "ア", "ィ", "イ", "ゥ", "ウ", "ヴ", "ェ", "エ", "ォ", "オ", "ヵ", "カ", "ガ", "キ", "ギ", "ク", "グ", "ヶ", "ケ", "ゲ", "コ", "ゴ", "サ", "ザ", "シ", "ジ", "〆", "ス", "ズ", "セ", "ゼ", "ソ", "ゾ", "タ", "ダ", "チ", "ヂ", "ッ", "ツ", "ヅ", "テ", "デ", "ト", "ド", "ナ", "ニ", "ヌ", "ネ", "ノ", "ハ", "バ", "パ", "ヒ", "ビ", "ピ", "フ", "ブ", "プ", "ヘ", "ベ", "ペ", "ホ", "ボ", "ポ", "マ", "ミ", "ム", "メ", "モ", "ャ", "ヤ", "ュ", "ユ", "ョ", "ヨ", "ラ", "リ", "ル", "レ", "ロ", "ヮ", "ワ", "ヰ", "ヱ", "ヲ", "ン", "仝", "&", "A", "！", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "？", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "^", "_", "=", "ㇻ", "(", ")", "#", "%", "'", "\"", "+", "-", "ㇼ", ".", " ", "!", "?", ",", ":", ";"]
            .enumerated()
            .map {
                (Character($0.element), UInt8($0.offset))
            }
    )

    /// これらの文字を含む単語はスキップする
    static let skipCharacters: Set<Character> = [
        "ヷ", "ヸ", "　", "\0"
    ]

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
