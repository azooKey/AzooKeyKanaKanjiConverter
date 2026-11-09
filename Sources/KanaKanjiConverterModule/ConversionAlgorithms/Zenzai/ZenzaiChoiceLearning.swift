import Foundation
import SwiftUtils

/// Explicit corrections, shared across the converter's sessions and independent of legacy memory.
struct ZenzaiChoiceLearning {
    private static let capacity = 256
    private static let maxReadingLength = 16
    private static let maxComparedSurfaces = 4
    private static let maxFileSize = 1 << 20

    struct Word: Codable, Equatable {
        let ruby: String
        let text: String
        let lcid: Int
        let rcid: Int
        let mid: Int
        let value: Float

        init(_ element: DicdataElement) {
            self.ruby = element.ruby
            self.text = element.word
            self.lcid = element.lcid
            self.rcid = element.rcid
            self.mid = element.mid
            self.value = Float(element.value())
        }

        var isValid: Bool {
            !ruby.isEmpty && ruby.utf8.count <= 64 && !text.isEmpty && text.utf8.count <= 128
                && (0..<CIDData.totalCount).contains(lcid) && (0..<CIDData.totalCount).contains(rcid) && (0..<502).contains(mid)
                && value.isFinite && (-1000...0).contains(value)
        }

        var element: DicdataElement {
            .init(word: text, ruby: ruby, lcid: lcid, rcid: rcid, mid: mid, value: PValue(value))
        }
    }

    struct Choice: Codable {
        let reading: String
        let first: [Word]
        let second: [Word]
        var votes: Int
        let wholeInputOnly: Bool?

        var firstText: String { first.map(\.text).joined() }
        var secondText: String { second.map(\.text).joined() }
        var isValid: Bool {
            (1...ZenzaiChoiceLearning.maxReadingLength).contains(reading.count) && reading.utf8.count <= 64
                && firstText.utf8.count <= 128 && secondText.utf8.count <= 128
                && !first.isEmpty && !second.isEmpty
                && first.count <= ZenzaiChoiceLearning.maxReadingLength && second.count <= ZenzaiChoiceLearning.maxReadingLength
                && first.allSatisfy(\.isValid) && second.allSatisfy(\.isValid)
                && first.map(\.ruby).joined() == reading && second.map(\.ruby).joined() == reading
                && firstText < secondText && (-8...8).contains(votes) && votes != 0
        }
    }

    struct Contrast {
        let rejected: String
        let maximumLogitGap: Float
        let canRerankWholeInput: Bool

        init(rejected: String, votes: Int, changesWordBoundaries: Bool) {
            self.rejected = rejected
            self.maximumLogitGap = Self.maximumLogitGap(votes: votes)
            self.canRerankWholeInput = changesWordBoundaries && self.maximumLogitGap.isInfinite
        }

        static func maximumLogitGap(votes: Int) -> Float {
            // Give the model five prior votes. A net preference of v wins when
            // v > prior * (1 - 2 * modelProbability). Solve for the logit gap
            // here so the evaluator only compares floats in its token loop.
            let prior: Float = 5
            let netVotes = Float(votes)
            return netVotes >= prior ? .infinity : logf((prior + netVotes) / (prior - netVotes))
        }
    }

    struct Preference {
        let preferred: [Word]
        let preferredText: String
        let reading: String
        var contrasts: [Contrast]
    }

    /// Offsets refer to the preferred draft's surface in UTF-8.
    struct Edit {
        let range: Range<Int>
        let coversWholeInput: Bool
        let contrasts: [Contrast]
    }

    private var records: [Choice] = []
    private(set) var preferences: [Character: [Preference]] = [:]
    private(set) var wholeInputPreferences: [String: [String: Preference]] = [:]
    private var file: URL?
    private var dirty = false

    @discardableResult
    mutating func configure(directory: URL) -> Bool {
        let file = directory.appendingPathComponent("zenzai-choices-v1.json")
        guard self.file != file else { return true }
        self.save()
        guard !self.dirty else { return false }
        self.file = file
        self.records = []
        if let handle = try? FileHandle(forReadingFrom: file),
           let data = try? handle.read(upToCount: Self.maxFileSize + 1),
           data.count <= Self.maxFileSize,
           let stored = try? JSONDecoder().decode([Choice].self, from: data) {
            self.records = stored.suffix(Self.capacity).filter(\.isValid)
        }
        self.reindex()
        return true
    }

    mutating func save() {
        guard self.dirty, let file = self.file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self.records).write(to: file, options: .atomic)
            self.dirty = false
        } catch {
            debug("Could not save Zenzai choice learning", error)
        }
    }

    mutating func reset() {
        self.records = []
        self.preferences = [:]
        self.wholeInputPreferences = [:]
        if self.file != nil {
            self.dirty = true
            self.save()
        }
    }

    mutating func forget(_ candidate: Candidate) {
        let oldCount = self.records.count
        self.records.removeAll { record in
            for start in candidate.data.indices {
                var reading = ""
                var text = ""
                for element in candidate.data[start...] {
                    reading += element.ruby
                    if !record.reading.hasPrefix(reading) { break }
                    text += element.word
                    if reading == record.reading {
                        if text == record.firstText || text == record.secondText { return true }
                        break
                    }
                }
            }
            return false
        }
        if self.records.count != oldCount {
            self.dirty = true
            self.reindex()
            self.save()
        }
    }

    private func matchingPrefix(of original: Candidate, reading: String) -> ArraySlice<DicdataElement>? {
        guard original.isLearningTarget, original.actions.isEmpty,
              original.data.map(\.word).joined() == original.text,
              original.data.allSatisfy({ !$0.ruby.isEmpty }) else { return nil }
        var unread = reading[...]
        let prefix = original.data.prefix { element in
            guard !unread.isEmpty, unread.hasPrefix(element.ruby) else { return false }
            unread = unread.dropFirst(element.ruby.count)
            return true
        }
        return !prefix.isEmpty && unread.isEmpty ? prefix : nil
    }

    mutating func record(from original: Candidate, to selected: Candidate) -> Bool {
        self.record(from: [original], to: selected)
    }

    mutating func record(from originals: [Candidate], to selected: Candidate) -> Bool {
        guard let first = originals.first, selected.isLearningTarget, selected.actions.isEmpty,
              selected.data.map(\.word).joined() == selected.text,
              selected.data.allSatisfy({ !$0.ruby.isEmpty }) else { return false }
        let reading = selected.data.map(\.ruby).joined()
        // The first candidate is the ordinary conversion. A selection that keeps
        // its surface in the chosen span supplies no correction.
        guard let prefix = self.matchingPrefix(of: first, reading: reading) else { return false }
        let surface = prefix.map(\.word).joined()
        guard surface != selected.text else { return false }

        var seen: Set<[String]> = []
        self.recordAligned(from: prefix, to: selected.data, seen: &seen)
        var compared: Set<String> = [surface]
        for alternative in originals.dropFirst() {
            guard let prefix = self.matchingPrefix(of: alternative, reading: reading) else { continue }
            let surface = prefix.map(\.word).joined()
            guard surface != selected.text, compared.insert(surface).inserted else { continue }
            self.recordAligned(from: prefix, to: selected.data, seen: &seen)
            if compared.count == Self.maxComparedSurfaces { break }
        }
        guard !seen.isEmpty else { return false }
        self.dirty = true
        self.reindex()
        return true
    }

    /// Align by shared reading boundaries. One selection supplies at most one vote for each pair.
    private mutating func recordAligned(from a: ArraySlice<DicdataElement>, to b: [DicdataElement], seen: inout Set<[String]>) {
        var i = 0, j = 0
        while i < a.count && j < b.count {
            let startI = i
            let startJ = j
            var left = a[i].ruby.count
            var right = b[j].ruby.count
            i += 1
            j += 1
            while left != right {
                if left < right, i < a.count {
                    left += a[i].ruby.count
                    i += 1
                } else if right < left, j < b.count {
                    right += b[j].ruby.count
                    j += 1
                } else {
                    return
                }
            }
            guard left <= Self.maxReadingLength else { continue }
            let originalPart = a[startI..<i]
            let selectedPart = b[startJ..<j]
            let rejectedText = originalPart.map(\.word).joined()
            let selectedText = selectedPart.map(\.word).joined()
            guard rejectedText != selectedText,
                  originalPart.allSatisfy({ $0.metadata.isEmpty }),
                  selectedPart.allSatisfy({ $0.metadata.isEmpty }) else { continue }
            let reading = originalPart.map(\.ruby).joined()
            let key = [reading, min(rejectedText, selectedText), max(rejectedText, selectedText)]
            guard !seen.contains(key),
                  self.recordPair(reading: reading, original: originalPart, selected: selectedPart, wholeInputOnly: false) else {
                continue
            }
            seen.insert(key)
        }
    }

    mutating func recordWholeInput(from original: Candidate, to selected: Candidate, existingOnly: Bool = false) -> Bool {
        guard original.isLearningTarget, selected.isLearningTarget, original.actions.isEmpty, selected.actions.isEmpty,
              original.text != selected.text, original.data.map(\.word).joined() == original.text,
              selected.data.map(\.word).joined() == selected.text,
              original.data.allSatisfy({ $0.metadata.isEmpty }), selected.data.allSatisfy({ $0.metadata.isEmpty }) else {
            return false
        }
        let reading = selected.data.map(\.ruby).joined()
        guard original.data.map(\.ruby).joined() == reading,
              self.recordPair(reading: reading, original: original.data[...], selected: selected.data[...],
                              wholeInputOnly: true, existingOnly: existingOnly) else {
            return false
        }
        self.dirty = true
        self.reindex()
        return true
    }

    @discardableResult
    private mutating func recordPair(
        reading: String,
        original: ArraySlice<DicdataElement>,
        selected: ArraySlice<DicdataElement>,
        wholeInputOnly: Bool,
        existingOnly: Bool = false
    ) -> Bool {
        let forward = original.map(\.word).joined() < selected.map(\.word).joined()
        let originalWords = original.map(Word.init)
        let selectedWords = selected.map(Word.init)
        var choice = Choice(reading: reading, first: forward ? originalWords : selectedWords,
                            second: forward ? selectedWords : originalWords, votes: forward ? 1 : -1,
                            wholeInputOnly: wholeInputOnly ? true : nil)
        guard choice.isValid else { return false }
        if let index = self.records.firstIndex(where: {
            $0.reading == reading && $0.firstText == choice.firstText && $0.secondText == choice.secondText
                && $0.wholeInputOnly == choice.wholeInputOnly
        }) {
            choice.votes = min(8, max(-8, self.records.remove(at: index).votes + choice.votes))
        } else if existingOnly {
            return false
        }
        if choice.votes != 0 {
            if self.records.count == Self.capacity { self.records.removeFirst() }
            self.records.append(choice)
        }
        return true
    }

    private mutating func reindex() {
        self.preferences = [:]
        self.wholeInputPreferences = [:]
        var indexedCounts: [Character: Int] = [:]
        for record in self.records.reversed() where abs(record.votes) >= 2 {
            if record.wholeInputOnly == true {
                let rejected = record.votes > 0 ? record.firstText : record.secondText
                if abs(record.votes) >= 5, self.wholeInputPreferences[record.reading]?[rejected] == nil {
                    self.wholeInputPreferences[record.reading, default: [:]][rejected] = Preference(
                        preferred: record.votes > 0 ? record.second : record.first,
                        preferredText: record.votes > 0 ? record.secondText : record.firstText,
                        reading: record.reading,
                        contrasts: []
                    )
                }
                continue
            }
            guard let firstKana = record.reading.first, indexedCounts[firstKana, default: 0] < 8 else { continue }
            indexedCounts[firstKana, default: 0] += 1
            let preferredText = record.votes > 0 ? record.secondText : record.firstText
            let contrast = Contrast(
                rejected: record.votes > 0 ? record.firstText : record.secondText,
                votes: abs(record.votes),
                changesWordBoundaries: record.first.count > 1 && record.second.count > 1
                    && record.first.map(\.ruby) != record.second.map(\.ruby)
            )
            var bucket = self.preferences[firstKana, default: []]
            if let index = bucket.firstIndex(where: { $0.reading == record.reading && $0.preferredText == preferredText }) {
                bucket[index].contrasts.append(contrast)
            } else {
                bucket.append(Preference(
                    preferred: record.votes > 0 ? record.second : record.first,
                    preferredText: preferredText,
                    reading: record.reading,
                    contrasts: [contrast]
                ))
            }
            self.preferences[firstKana] = bucket
        }
    }
}

extension Kana2Kanji {
    /// Build one competing draft by replacing complete reading spans on the ordinary path.
    /// The ordinary path remains available without a second lattice traversal.
    func choiceDraft(
        from node: RegisteredNode,
        reading: String,
        preferences: [Character: [ZenzaiChoiceLearning.Preference]]
    ) -> (RegisteredNode, [ZenzaiChoiceLearning.Edit])? {
        var path: [RegisteredNode] = []
        var cursor: RegisteredNode? = node
        while let current = cursor, current.prev != nil {
            path.append(current)
            cursor = current.prev
        }
        path.reverse()
        guard let head = cursor, path.map({ $0.data.ruby }).joined() == reading else { return nil }

        var replacements: [(range: Range<Int>, preference: ZenzaiChoiceLearning.Preference)] = []
        var i = 0
        while i < path.count && replacements.count < 8 {
            let variants = path[i].data.ruby.first.flatMap { preferences[$0] } ?? []
            let start = i
            for preference in variants {
                var reading = ""
                var surface = ""
                var end = start
                while end < path.count, reading.count < preference.reading.count, path[end].data.metadata.isEmpty {
                    reading += path[end].data.ruby
                    surface += path[end].data.word
                    end += 1
                    if !preference.reading.hasPrefix(reading) { break }
                }
                guard reading == preference.reading, surface != preference.preferredText else { continue }
                // Keep a tightly attached continuation when the replacement makes its
                // dictionary connection much less likely, such as a surname before ます.
                if end < path.count, let preferredLast = preference.preferred.last {
                    let originalRCID = path[end - 1].data.rcid
                    let nextLCID = path[end].data.lcid
                    if !DicdataStore.isClause(originalRCID, nextLCID),
                       self.dicdataStore.getCCValue(originalRCID, nextLCID)
                           - self.dicdataStore.getCCValue(preferredLast.rcid, nextLCID) > 8 {
                        continue
                    }
                }
                replacements.append((start..<end, preference))
                i = end
                break
            }
            if i == start { i += 1 }
        }
        guard !replacements.isEmpty else { return nil }

        var draft = head
        var edits: [ZenzaiChoiceLearning.Edit] = []
        var offset = 0
        var surface = 0
        func append(_ element: DicdataElement, range: Lattice.LatticeRange) {
            let connection = self.dicdataStore.getCCValue(draft.data.rcid, element.lcid)
            draft = RegisteredNode(data: element, registered: draft,
                                   totalValue: draft.totalValue + element.value() + connection, range: range)
            offset += element.word.utf8.count
            surface += element.ruby.count
        }
        var index = 0
        for (range, preference) in replacements {
            for existing in path[index..<range.lowerBound] {
                append(existing.data, range: existing.range)
            }
            let startOffset = offset
            for word in preference.preferred {
                append(word.element, range: .surface(from: surface, to: surface + word.ruby.count))
            }
            edits.append(.init(
                range: startOffset..<offset,
                coversWholeInput: range == path.indices,
                contrasts: preference.contrasts
            ))
            index = range.upperBound
        }
        for existing in path[index...] {
            append(existing.data, range: existing.range)
        }
        return (draft, edits)
    }
}
