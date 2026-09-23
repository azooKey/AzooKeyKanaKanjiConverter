@testable import KanaKanjiConverterModule
import XCTest

final class EnglishDictionaryTests: XCTestCase {
    private func withDictionary(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EnglishDictionary-\(UUID().uuidString)")
        let source = Bundle.module.resourceURL!.appendingPathComponent("DictionaryMock")
        try FileManager.default.copyItem(at: source, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let louds = url.appendingPathComponent("louds")
        let chars = try String(contentsOf: louds.appendingPathComponent("charID.chid"), encoding: .utf8)
        let map = Dictionary(uniqueKeysWithValues: chars.enumerated().map { ($0.element, UInt8($0.offset)) })
        let entries = [
            DicdataElement(word: "Yahoo!", ruby: "Yahoo!", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "yahoo!", ruby: "yahoo!", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "Who?", ruby: "Who?", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "Hello, World", ruby: "Hello, World", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "Key:Value", ruby: "Key:Value", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "Steins;Gate", ruby: "Steins;Gate", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "key=value", ruby: "key=value", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "Ready! Go", ruby: "Ready! Go", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "Key=", ruby: "Key=", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "invalid!!_", ruby: "invalid!!_", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "New York", ruby: "New York", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "new york", ruby: "new york", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "U.S. Army", ruby: "U.S. Army", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "dogs' food", ruby: "dogs' food", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "AT&T Inc.", ruby: "AT&T Inc.", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "3M Company", ruby: "3M Company", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "New  Invalid_", ruby: "New  Invalid_", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "New Invalid_", ruby: "New Invalid_", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "don't", ruby: "don't", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "Don't", ruby: "Don't", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "don’t", ruby: "don’t", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "I'm", ruby: "I'm", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "O'Reilly", ruby: "O'Reilly", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "dogs'", ruby: "dogs'", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "dogs’", ruby: "dogs’", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "AT&T", ruby: "AT&T", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "R&D", ruby: "R&D", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "U.S.", ruby: "U.S.", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "Node.js", ruby: "Node.js", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "v1.2", ruby: "v1.2", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "word&_", ruby: "word&_", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "word..x_", ruby: "word..x_", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "GPT-4", ruby: "GPT-4", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -7),
            DicdataElement(word: "gpt-4", ruby: "gpt-4", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -9),
            DicdataElement(word: "GPT-5", ruby: "GPT-5", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10),
            DicdataElement(word: "GPT4", ruby: "GPT4", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -11),
            DicdataElement(word: "3M", ruby: "3M", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "Wi-Fi", ruby: "Wi-Fi", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10),
            DicdataElement(word: "123", ruby: "123", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -1),
            DicdataElement(word: "GitHub", ruby: "GitHub", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8),
            DicdataElement(word: "GitLab", ruby: "GitLab", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10),
            DicdataElement(word: "github", ruby: "github", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -9),
            DicdataElement(word: "QzEnglishFixture", ruby: "QzEnglishFixture", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -1),
            // 同じ表記が複数エントリにあっても、候補はスコアの高い一件にする。
            DicdataElement(word: "GitHub", ruby: "GitHub", cid: CIDData.固有名詞.cid, mid: MIDData.組織.mid, value: -12),
            DicdataElement(word: "ギット", ruby: "Git", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -1)
        ]
        try DictionaryBuilder.exportDictionary(entries: entries, to: louds, baseName: "", shardByFirstCharacter: true, char2UInt8: map)
        try body(url)
    }

    func testAsymmetricCaseMatchingPreservesSurfaceAndScore() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            let prefix = converter.getEnglishDictionaryCandidates(ruby: "Git", inputCount: 3, penalty: -5)
            XCTAssertEqual(prefix.map(\.text), ["GitHub", "GitLab"])
            XCTAssertEqual(prefix.first?.value, -13)
            XCTAssertEqual(prefix.first?.composingCount, .inputCount(3))
            XCTAssertEqual(prefix.first?.data.first?.ruby, "GitHub")
            XCTAssertEqual(prefix.first?.data.first?.value(), -8)
            XCTAssertEqual(converter.getEnglishDictionaryCandidates(ruby: "GitHub", inputCount: 6, penalty: -5).map(\.text), ["GitHub"])
            XCTAssertEqual(converter.getEnglishDictionaryCandidates(ruby: "git", inputCount: 3, penalty: -5).map(\.text), ["GitHub", "github", "GitLab"])
            XCTAssertTrue(converter.getEnglishDictionaryCandidates(ruby: "GIT", inputCount: 3, penalty: -5).isEmpty)
            XCTAssertEqual(converter.getEnglishDictionaryCandidates(ruby: "gi", inputCount: 2, penalty: -5).map(\.text), ["GitHub", "github", "GitLab"])
            XCTAssertEqual(converter.getEnglishDictionaryCandidates(ruby: "Gi", inputCount: 2, penalty: -5).map(\.text), ["GitHub", "GitLab"])
            XCTAssertEqual(converter.getEnglishDictionaryCandidates(ruby: "github", inputCount: 6, penalty: -5).map(\.text), ["GitHub", "github"])
            XCTAssertEqual(converter.getEnglishDictionaryCandidates(ruby: "gitH", inputCount: 4, penalty: -5).map(\.text), ["GitHub"])
            XCTAssertTrue(converter.getEnglishDictionaryCandidates(ruby: "gIt", inputCount: 3, penalty: -5).isEmpty)
            for key in ["", "Git4", "ギット", "café"] {
                XCTAssertTrue(converter.getEnglishDictionaryCandidates(ruby: key, inputCount: key.count, penalty: -5).isEmpty)
            }
        }
    }

    func testUserAndLearnedDictionariesUseTheSameCaseRule() throws {
        try withDictionary { url in
            let chars = try String(contentsOf: url.appendingPathComponent("louds/charID.chid"), encoding: .utf8)
            let map = Dictionary(uniqueKeysWithValues: chars.enumerated().map { ($0.element, UInt8($0.offset)) })
            let entries = ["UserCase", "usercase"].map {
                DicdataElement(word: $0, ruby: $0, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8)
            }
            let userURL = url.appendingPathComponent("user-dictionary")
            try FileManager.default.createDirectory(at: userURL, withIntermediateDirectories: true)
            try DictionaryBuilder.exportDictionary(entries: entries, to: userURL, baseName: "user", shardByFirstCharacter: false, char2UInt8: map)
            let store = DicdataStore(dictionaryURL: url)
            let state = store.prepareState()
            state.updateUserDictionaryURL(userURL, forceReload: false)
            XCTAssertEqual(Set(store.getEnglishPredictionDicdata(key: "user", state: state).map(\.word)), ["UserCase", "usercase"])
            XCTAssertEqual(store.getEnglishPredictionDicdata(key: "User", state: state).map(\.word), ["UserCase"])

            state.updateLearningConfig(.init(learningType: .inputAndOutput, maxMemoryCount: 100, memoryURL: url))
            let learned = ["LearnedWord", "learnedword"].map {
                DicdataElement(word: $0, ruby: $0, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8)
            }
            for entry in learned { state.learningMemoryManager.update(data: [entry]) }
            XCTAssertEqual(Set(store.getEnglishPredictionDicdata(key: "learned", state: state).map(\.word)), ["LearnedWord", "learnedword"])
            XCTAssertEqual(store.getEnglishPredictionDicdata(key: "Learned", state: state).map(\.word), ["LearnedWord"])
        }
    }

    func testBranchingSearchHandlesLongKeysAndBoundsResults() throws {
        try withDictionary { url in
            let chars = try String(contentsOf: url.appendingPathComponent("louds/charID.chid"), encoding: .utf8)
            let map = Dictionary(uniqueKeysWithValues: chars.enumerated().map { ($0.element, UInt8($0.offset)) })
            let word = String(repeating: "aB", count: 20)
            let entries = [word, word + "Suffix"].map {
                DicdataElement(word: $0, ruby: $0, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8)
            }
            try DictionaryBuilder.exportDictionary(entries: entries, to: url, baseName: "user", shardByFirstCharacter: false, char2UInt8: map)
            let louds = try XCTUnwrap(LOUDS.loadUserDictionary(userDictionaryURL: url))
            let options = word.lowercased().map { [map[$0]!, map[Character(String($0).uppercased())]!] }
            let exact = try XCTUnwrap(louds.searchNodeIndex(chars: word.map { map[$0]! }))
            XCTAssertEqual(louds.prefixNodeIndices(charOptions: options, maxCount: 1), [exact])
            XCTAssertEqual(louds.prefixNodeIndices(charOptions: options, maxCount: 0), [])
            XCTAssertGreaterThan(louds.prefixNodeIndices(charOptions: options, maxCount: 700).count, 1)
            XCTAssertTrue(louds.prefixNodeIndices(charOptions: options + [[map["z"]!]], maxCount: 700).isEmpty)

            var memory = TemporalLearningMemoryTrie()
            for entry in entries { memory.memorize(dicdataElement: entry, chars: entry.ruby.map { map[$0]! }) }
            XCTAssertEqual(memory.prefixMatch(charOptions: options, maxCount: 1).map(\.word), [word])
            XCTAssertEqual(Set(memory.prefixMatch(charOptions: options, maxCount: 700).map(\.word)), Set(entries.map(\.word)))
        }
    }

    func testAlphanumericAndHyphenatedDictionaryCandidates() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            func words(_ prefix: String) -> [String] {
                converter.getEnglishDictionaryCandidates(ruby: prefix, inputCount: prefix.count, penalty: -5).map(\.text)
            }
            XCTAssertEqual(words("gpt-"), ["GPT-4", "gpt-4", "GPT-5"])
            XCTAssertEqual(words("GPT-"), ["GPT-4", "GPT-5"])
            XCTAssertEqual(words("gpt-4"), ["GPT-4", "gpt-4"])
            XCTAssertEqual(words("GPT-4"), ["GPT-4"])
            XCTAssertEqual(words("gpt4"), ["GPT4"])
            XCTAssertEqual(words("3"), ["3M", "3M Company"])
            XCTAssertEqual(words("3m"), ["3M", "3M Company"])
            XCTAssertEqual(words("wi-"), ["Wi-Fi"])
            XCTAssertEqual(words("wi-fi"), ["Wi-Fi"])
            for key in ["gpt-3", "123", "123-456", "-GPT", "GPT--", "GPT_", "GPT  ", "WI-FI"] {
                XCTAssertTrue(words(key).isEmpty, key)
            }
            for text in ["gpt-", "gpt-4"] {
                var input = ComposingText()
                input.insertAtCursorPosition(text, inputStyle: .direct)
                let result = converter.requestCandidates(input, options: options(at: url, english: .manualMix, roman: false))
                XCTAssertTrue(result.englishPredictionResults.contains { $0.text == "GPT-4" })
            }
        }
    }

    func testPunctuationPreservesSpellingAndReachesPrediction() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            func words(_ prefix: String) -> Set<String> {
                Set(converter.getEnglishDictionaryCandidates(ruby: prefix, inputCount: prefix.count, penalty: -5).map(\.text))
            }
            XCTAssertEqual(words("don'"), ["don't", "Don't"])
            XCTAssertEqual(words("Don't"), ["Don't"])
            XCTAssertEqual(words("don’"), ["don’t"])
            XCTAssertEqual(words("i'"), ["I'm"])
            XCTAssertEqual(words("o'r"), ["O'Reilly"])
            XCTAssertEqual(words("dogs'"), ["dogs'", "dogs' food"])
            XCTAssertEqual(words("dogs’"), ["dogs’"])
            XCTAssertEqual(words("at&"), ["AT&T", "AT&T Inc."])
            XCTAssertEqual(words("r&d"), ["R&D"])
            XCTAssertEqual(words("u.s."), ["U.S.", "U.S. Army"])
            XCTAssertEqual(words("node."), ["Node.js"])
            XCTAssertEqual(words("v1."), ["v1.2"])
            for key in ["dont", "at-t", "us", "word", "&", "'", "’", ".", "u..", "don’’"] {
                XCTAssertTrue(words(key).isEmpty, key)
            }
            for (text, expected) in [("don'", "don't"), ("don’", "don’t"), ("at&", "AT&T"), ("u.s.", "U.S.")] {
                var input = ComposingText()
                input.insertAtCursorPosition(text, inputStyle: .direct)
                let result = converter.requestCandidates(input, options: options(at: url, english: .manualMix, roman: false))
                let candidate = try XCTUnwrap(result.englishPredictionResults.first { $0.text == expected })
                XCTAssertEqual(candidate.composingCount, .inputCount(text.count))
                XCTAssertEqual(candidate.data.first?.ruby, expected)
            }
        }
    }

    func testSpaceSeparatedPhrasesPreserveCaseAndReachPrediction() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            func words(_ prefix: String) -> Set<String> {
                Set(converter.getEnglishDictionaryCandidates(ruby: prefix, inputCount: prefix.count, penalty: -5).map(\.text))
            }
            XCTAssertEqual(words("new"), ["New York", "new york"])
            XCTAssertEqual(words("new "), ["New York", "new york"])
            XCTAssertEqual(words("new y"), ["New York", "new york"])
            XCTAssertEqual(words("new York"), ["New York"])
            XCTAssertEqual(words("New York"), ["New York"])
            XCTAssertEqual(words("u.s. "), ["U.S. Army"])
            XCTAssertEqual(words("dogs' "), ["dogs' food"])
            XCTAssertEqual(words("at&t "), ["AT&T Inc."])
            XCTAssertEqual(words("3m "), ["3M Company"])
            for key in [" new", "new  ", "newyork", "new\t", "new　", "NEW ", "new- "] {
                XCTAssertTrue(words(key).isEmpty, key)
            }
            for (text, expected) in [("new ", "New York"), ("new york", "New York"), ("u.s. ", "U.S. Army")] {
                var input = ComposingText()
                input.insertAtCursorPosition(text, inputStyle: .direct)
                XCTAssertEqual(input.convertTarget, text)
                let result = converter.requestCandidates(input, options: options(at: url, english: .manualMix, roman: false))
                let candidate = try XCTUnwrap(result.englishPredictionResults.first { $0.text == expected })
                XCTAssertEqual(candidate.composingCount, .inputCount(text.count))
                XCTAssertEqual(candidate.data.first?.ruby, expected)
            }
        }
    }

    func testSpaceSeparatedUserAndLearnedDictionaryEntries() throws {
        try withDictionary { url in
            let chars = try String(contentsOf: url.appendingPathComponent("louds/charID.chid"), encoding: .utf8)
            let map = Dictionary(uniqueKeysWithValues: chars.enumerated().map { ($0.element, UInt8($0.offset)) })
            let entries = ["User Phrase", "user phrase"].map {
                DicdataElement(word: $0, ruby: $0, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8)
            }
            let userURL = url.appendingPathComponent("user-dictionary")
            try FileManager.default.createDirectory(at: userURL, withIntermediateDirectories: true)
            try DictionaryBuilder.exportDictionary(entries: entries, to: userURL, baseName: "user", shardByFirstCharacter: false, char2UInt8: map)
            let store = DicdataStore(dictionaryURL: url)
            let state = store.prepareState()
            state.updateUserDictionaryURL(userURL, forceReload: false)
            XCTAssertEqual(Set(store.getEnglishPredictionDicdata(key: "user ", state: state).map(\.word)), ["User Phrase", "user phrase"])
            XCTAssertEqual(store.getEnglishPredictionDicdata(key: "User P", state: state).map(\.word), ["User Phrase"])
            state.updateLearningConfig(.init(learningType: .inputAndOutput, maxMemoryCount: 100, memoryURL: url))
            let entry = DicdataElement(word: "Learned Phrase", ruby: "Learned Phrase", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8)
            state.learningMemoryManager.update(data: [entry])
            XCTAssertEqual(store.getEnglishPredictionDicdata(key: "learned ", state: state).map(\.word), ["Learned Phrase"])
            XCTAssertTrue(store.getEnglishPredictionDicdata(key: "learnedphrase", state: state).isEmpty)
        }
    }

    func testAdditionalPunctuationPreservesExactCharacters() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            func words(_ prefix: String) -> Set<String> {
                Set(converter.getEnglishDictionaryCandidates(ruby: prefix, inputCount: prefix.count, penalty: -5).map(\.text))
            }
            XCTAssertEqual(words("yahoo!"), ["Yahoo!", "yahoo!"])
            XCTAssertEqual(words("Yahoo!"), ["Yahoo!"])
            XCTAssertEqual(words("who?"), ["Who?"])
            XCTAssertEqual(words("hello, "), ["Hello, World"])
            XCTAssertEqual(words("key:"), ["Key:Value"])
            XCTAssertEqual(words("steins;"), ["Steins;Gate"])
            XCTAssertEqual(words("key="), ["key=value", "Key="])
            XCTAssertEqual(words("Key="), ["Key="])
            XCTAssertEqual(words("ready! "), ["Ready! Go"])
            for key in ["yahoo?", "yahoo！", "who!", "hello;", "key;", "steins:", "key==", "!", "?", ",", ":", ";", "=", "invalid"] {
                XCTAssertTrue(words(key).isEmpty, key)
            }
            for (text, expected) in [("yahoo!", "Yahoo!"), ("who?", "Who?"), ("hello, ", "Hello, World"), ("key:", "Key:Value"), ("steins;", "Steins;Gate"), ("key=", "key=value")] {
                var input = ComposingText()
                input.insertAtCursorPosition(text, inputStyle: .direct)
                let result = converter.requestCandidates(input, options: options(at: url, english: .manualMix, roman: false))
                let candidate = try XCTUnwrap(result.englishPredictionResults.first { $0.text == expected })
                XCTAssertEqual(candidate.composingCount, .inputCount(text.count))
                XCTAssertEqual(candidate.data.first?.ruby, expected)
            }
        }
    }

    func testSymbolsAndSpacesAreAllowedAtAnyPosition() throws {
        try withDictionary { url in
            let louds = url.appendingPathComponent("louds")
            let chars = try String(contentsOf: louds.appendingPathComponent("charID.chid"), encoding: .utf8)
            let map = Dictionary(uniqueKeysWithValues: chars.enumerated().map { ($0.element, UInt8($0.offset)) })
            let words = [".NET", "=LOVE", "=love", "Yahoo!!", " What!? ", "Two  Words", "R & D"]
                + "-'’&.!?,:;= ".map { String($0) + "Brand" }
            let entries = words.map { DicdataElement(word: $0, ruby: $0, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8) }
            try DictionaryBuilder.exportDictionary(entries: entries, to: louds, baseName: "", shardByFirstCharacter: true, char2UInt8: map)
            let converter = KanaKanjiConverter(dictionaryURL: url)
            func candidates(_ key: String) -> [Candidate] {
                converter.getEnglishDictionaryCandidates(ruby: key, inputCount: key.count, penalty: -5)
            }
            for word in words {
                XCTAssertTrue(candidates(String(word.prefix(1))).contains { $0.text == word }, word)
                let key = word.lowercased()
                let candidate = try XCTUnwrap(candidates(key).first { $0.text == word }, word)
                XCTAssertEqual(candidate.data.first?.ruby, word)
                var input = ComposingText()
                input.insertAtCursorPosition(key, inputStyle: .direct)
                XCTAssertEqual(input.convertTarget, key)
                let result = converter.requestCandidates(input, options: options(at: url, english: .manualMix, roman: false))
                let prediction = try XCTUnwrap(result.englishPredictionResults.first { $0.text == word }, word)
                XCTAssertEqual(prediction.composingCount, .inputCount(key.count))
            }
            XCTAssertEqual(Set(candidates("=love").map(\.text)), ["=LOVE", "=love"])
            XCTAssertEqual(candidates("=LOVE").map(\.text), ["=LOVE"])
            for key in ["NET", "What!?", "Two Words", "Yahoo?", "R&D"] {
                XCTAssertTrue(candidates(key).isEmpty, key)
            }
        }
    }

    private func options(at url: URL, english: ConvertRequestOptions.PredictionMode, roman: Bool) -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 10, requireJapanesePrediction: .disabled, requireEnglishPrediction: english,
            keyboardLanguage: .en_US, englishCandidateInRoman2KanaInput: roman,
            learningType: .nothing, memoryDirectoryURL: url, sharedContainerURL: url,
            textReplacer: .empty, specialCandidateProviders: [], metadata: nil
        )
    }

    func testDictionaryCandidatesReachEnglishPredictionAndRespectDisabledMode() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            var input = ComposingText()
            input.insertAtCursorPosition("qzeng", inputStyle: .direct)
            let result = converter.requestCandidates(input, options: options(at: url, english: .manualMix, roman: false))
            XCTAssertTrue(result.englishPredictionResults.contains { $0.text == "QzEnglishFixture" })
            XCTAssertFalse(result.mainResults.contains { $0.text == "QzEnglishFixture" })
            let mixed = converter.requestCandidates(input, options: options(at: url, english: .autoMix, roman: false))
            XCTAssertTrue(mixed.englishPredictionResults.contains { $0.text == "QzEnglishFixture" })
            XCTAssertTrue(mixed.mainResults.contains { $0.text == "QzEnglishFixture" })
            let disabled = converter.requestCandidates(input, options: options(at: url, english: .disabled, roman: false))
            XCTAssertTrue(disabled.englishPredictionResults.isEmpty)
            XCTAssertFalse(disabled.mainResults.contains { $0.text == "QzEnglishFixture" })
        }
    }

    func testDictionaryCandidatesReachRomanInputMixing() throws {
        try withDictionary { url in
            let converter = KanaKanjiConverter(dictionaryURL: url)
            var input = ComposingText()
            input.insertAtCursorPosition("qzeng", inputStyle: .roman2kana)
            var request = options(at: url, english: .disabled, roman: true)
            request.keyboardLanguage = .ja_JP
            let result = converter.requestCandidates(input, options: request)
            XCTAssertTrue(result.mainResults.contains { $0.text == "QzEnglishFixture" })
        }
    }
}
