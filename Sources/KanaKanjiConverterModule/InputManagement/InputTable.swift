import SwiftUtils
private indirect enum TrieNode {
    struct State: Sendable, Equatable, Hashable {
        var resolvedAny1: InputPiece?
    }

    case node(output: [InputTable.ValueElement]?, charChildren: [Character: TrieNode] = [:], separatorChild: TrieNode? = nil, any1Child: TrieNode? = nil)

    // Recursively insert a reversed key path and set the output when the path ends.
    mutating func add(reversedKey: some Collection<InputTable.KeyElement>, output: [InputTable.ValueElement]) {
        guard let head = reversedKey.first else {
            // Reached the end of the key; store kana
            switch self {
            case let .node(_, charChildren, separatorChild, any1Child):
                self = .node(output: output, charChildren: charChildren, separatorChild: separatorChild, any1Child: any1Child)
            }
            return
        }
        let rest = reversedKey.dropFirst()
        switch self {
        case .node(let currentOutput, var charChildren, var separatorChild, var any1Child):
            var next: TrieNode
            switch head {
            case .any1:
                next = any1Child ?? .node(output: nil)
                next.add(reversedKey: rest, output: output)
                any1Child = next
            case .piece(let piece):
                switch piece {
                case .character(let c):
                    next = charChildren[c] ?? .node(output: nil)
                    next.add(reversedKey: rest, output: output)
                    charChildren[c] = next
                case .compositionSeparator:
                    next = separatorChild ?? .node(output: nil)
                    next.add(reversedKey: rest, output: output)
                    separatorChild = next
                }
            }
            self = .node(output: currentOutput, charChildren: charChildren, separatorChild: separatorChild, any1Child: any1Child)
        }
    }

    /// Fast check for whether this node has an output.
    var hasOutput: Bool {
        switch self { case .node(let output, _, _, _): return output != nil }
    }

    /// Returns the kana sequence stored at this node, resolving `.any1`
    /// placeholders in the *output* side using `state.resolvedAny1`
    /// (which is set when a wildcard edge was taken during the lookup).
    func outputValue(state: State) -> [Character]? {
        switch self {
        case .node(let output, _, _, _):
            output?.compactMap { elem in
                switch elem {
                case .character(let c): c
                case .any1:
                    // Replace `.any1` with the character captured when a
                    // wildcard edge was followed. If none is available,
                    // we return the NUL character so the caller can treat
                    // it as an invalid match.
                    switch state.resolvedAny1 {
                    case .character(let c): c
                    case .compositionSeparator, nil: nil
                    }
                }
            }
        }
    }
}

struct InputTable: Sendable {
    static let empty = InputTable(pieceHiraganaChanges: [:])

    /// Suffix‑oriented trie used for O(m) longest‑match lookup.
    enum KeyElement: Sendable, Equatable, Hashable {
        case piece(InputPiece)
        case any1
    }

    enum ValueElement: Sendable, Equatable, Hashable {
        case character(Character)
        case any1
    }

    init(pieceHiraganaChanges: [[KeyElement]: [ValueElement]]) {
        self.unstableSuffixes = pieceHiraganaChanges.keys.flatMapSet { pieces in
            pieces.indices.map { i in
                pieces[...i].compactMap { element in
                    if case let .piece(piece) = element, case let .character(c) = piece { c } else { nil }
                }
            }
        }
        let katakanaChanges: [String: String] = Dictionary(uniqueKeysWithValues: pieceHiraganaChanges.compactMap { key, value -> (String, String)? in
            let chars = key.compactMap { element -> Character? in
                if case let .piece(piece) = element, case let .character(c) = piece { c } else { nil }
            }
            guard chars.count == key.count else { return nil }
            let valueChars = value.compactMap {
                if case let .character(c) = $0 { c } else { nil }
            }
            return (String(chars), String(valueChars).toKatakana())
        })
        self.maxKeyCount = pieceHiraganaChanges.keys.map { $0.count }.max() ?? 0
        self.possibleNexts = {
            var results: [String: [String]] = [:]
            for (key, value) in katakanaChanges {
                for prefixCount in 0 ..< key.count where 0 < prefixCount {
                    let prefix = String(key.prefix(prefixCount))
                    results[prefix, default: []].append(value)
                }
            }
            return results
        }()
        var root: TrieNode = .node(output: nil, charChildren: [:], separatorChild: nil, any1Child: nil)
        for (key, value) in pieceHiraganaChanges {
            root.add(reversedKey: key.reversed().map { $0 }, output: value)
        }
        self.trieRoot = root
    }

    let unstableSuffixes: Set<[Character]>
    let maxKeyCount: Int
    let possibleNexts: [String: [String]]

    /// Root of the suffix‑trie built from `pieceHiraganaChanges`.
    private let trieRoot: TrieNode

    // Helper: return the child node for `elem`, if it exists.
    private static func childPiece(of node: TrieNode, _ piece: InputPiece) -> TrieNode? {
        switch node {
        case .node(_, let charChildren, let separatorChild, _):
            switch piece {
            case .character(let c): charChildren[c]
            case .compositionSeparator: separatorChild
            }
        }
    }

    private static func childAny1(of node: TrieNode) -> TrieNode? {
        switch node {
        case .node(_, _, _, let any1Child): any1Child
        }
    }

    // Non-recursive DFS: prefer concrete edge; then try `.any1` fallback.
    // Keeps the deepest match; for ties at same depth, prefers fewer `.any1` hops.
    // Returns the best node/state so the caller resolves the output once.
    private static func matchGreedy(root: TrieNode, buffer: [Character], added: InputPiece, maxKeyCount: Int) -> (node: TrieNode, state: TrieNode.State, depth: Int)? {
        struct Frame {
            var node: TrieNode
            var state: TrieNode.State
            var depth: Int
            var any1: Int
        }
        var best: (node: TrieNode, state: TrieNode.State, depth: Int, any1: Int)?

        @inline(__always)
        func pieceAt(_ depth: Int) -> InputPiece? {
            if depth == 0 {
                return added
            }
            let idx = buffer.count - depth
            if idx < 0 || idx >= buffer.count {
                return nil
            }
            return .character(buffer[idx])
        }

        var stack: [Frame] = [Frame(node: root, state: .init(), depth: 0, any1: 0)]
        stack.reserveCapacity(max(2, maxKeyCount))

        while let top = stack.popLast() {
            guard top.depth < maxKeyCount, let piece = pieceAt(top.depth) else {
                continue
            }

            // 1) Concrete edge (preferred)
            if let next = childPiece(of: top.node, piece) {
                if next.hasOutput {
                    if best == nil || top.depth + 1 > best!.depth || (top.depth + 1 == best!.depth && top.any1 < best!.any1) {
                        best = (next, top.state, top.depth + 1, top.any1)
                    }
                }
                stack.append(Frame(node: next, state: top.state, depth: top.depth + 1, any1: top.any1))
            }

            // 2) `.any1` fallback (only if compatible)
            if (top.state.resolvedAny1 ?? piece) == piece, let nextAny = childAny1(of: top.node) {
                var newState = top.state
                if newState.resolvedAny1 == nil {
                    newState.resolvedAny1 = piece
                }
                if nextAny.hasOutput {
                    if best == nil || top.depth + 1 > best!.depth || (top.depth + 1 == best!.depth && top.any1 + 1 < best!.any1) {
                        best = (nextAny, newState, top.depth + 1, top.any1 + 1)
                    }
                }
                stack.append(Frame(node: nextAny, state: newState, depth: top.depth + 1, any1: top.any1 + 1))
            }
        }

        return best.map { ($0.node, $0.state, $0.depth) }
    }

    /// Convert roman/katakana input pieces into hiragana.
    /// `any1` edges serve strictly as fall‑backs: a concrete `.piece`
    /// transition always has priority and we only follow `.any1`
    /// when no direct edge exists at the same depth.
    ///
    /// The algorithm walks the suffix‑trie from the newly added piece
    /// backwards, examining at most `maxKeyCount` pieces, and keeps the
    /// longest match.
    func toHiragana(currentText: [Character], added: InputPiece) -> [Character] {
        // Greedy match without temporary array allocation.
        let bestMatch = Self.matchGreedy(root: self.trieRoot, buffer: currentText, added: added, maxKeyCount: self.maxKeyCount)

        // Apply the result or fall back to passthrough behaviour.
        if let (bestNode, bestState, matchedDepth) = bestMatch, let kana = bestNode.outputValue(state: bestState) {
            // `matchedDepth` includes `added`, so drop `matchedDepth - 1` chars.
            return Array(currentText.dropLast(matchedDepth - 1)) + kana
        }

        // In case where no match found
        switch added {
        case .character(let ch):
            return currentText + [ch]
        case .compositionSeparator:
            return currentText
        }
    }

    /// In‑place variant: mutates `buffer` and returns (deleted, added) counts.
    /// Semantics match `toHiragana(currentText:added:)` but avoids new allocations
    /// when possible by editing the tail of `buffer` directly.
    borrowing func apply(to buffer: inout [Character], added: InputPiece) {
        // Greedy match without temporary array allocation.
        let bestMatch = Self.matchGreedy(root: self.trieRoot, buffer: buffer, added: added, maxKeyCount: self.maxKeyCount)

        if let (bestNode, bestState, matchedDepth) = bestMatch, let kana = bestNode.outputValue(state: bestState) {
            let deleteCount = max(0, matchedDepth - 1)
            if deleteCount > 0 {
                buffer.removeLast(deleteCount)
            }
            if !kana.isEmpty {
                buffer.append(contentsOf: kana)
            }
            return
        }

        switch added {
        case .character(let ch):
            buffer.append(ch)
        case .compositionSeparator:
            break
        }
    }
}
