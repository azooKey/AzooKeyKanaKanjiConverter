import OrderedCollections
import SwiftUtils
private indirect enum TrieNode {
    struct State: Sendable, Equatable, Hashable {
        var resolvedAny1: InputPiece?
    }

    struct KeySignature: Sendable, Equatable, Hashable {
        var input: Character
        var modifiers: Set<InputPiece.Modifier>
    }

    case node(output: [InputTable.ValueElement]?, charChildren: [Character: TrieNode] = [:], separatorChild: TrieNode? = nil, any1Child: TrieNode? = nil, keyChildren: [KeySignature: TrieNode] = [:])

    // Recursively insert a reversed key path and set the output when the path ends.
    mutating func add(reversedKey: some Collection<InputTable.KeyElement>, output: [InputTable.ValueElement]) {
        guard let head = reversedKey.first else {
            // Reached the end of the key; store kana
            switch self {
            case let .node(_, charChildren, separatorChild, any1Child, keyChildren):
                self = .node(output: output, charChildren: charChildren, separatorChild: separatorChild, any1Child: any1Child, keyChildren: keyChildren)
            }
            return
        }
        let rest = reversedKey.dropFirst()
        switch self {
        case .node(let currentOutput, var charChildren, var separatorChild, var any1Child, var keyChildren):
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
                case .key(let intention, let input, let modifiers):
                    let sig = KeySignature(input: input, modifiers: modifiers)
                    next = keyChildren[sig] ?? .node(output: nil)
                    next.add(reversedKey: rest, output: output)
                    keyChildren[sig] = next
                }
            }
            self = .node(output: currentOutput, charChildren: charChildren, separatorChild: separatorChild, any1Child: any1Child, keyChildren: keyChildren)
        }
    }

    /// Fast check for whether this node has an output.
    var hasOutput: Bool {
        switch self { case .node(let output, _, _, _, _): return output != nil }
    }

    /// Returns the kana sequence stored at this node, resolving `.any1`
    /// placeholders in the *output* side using `state.resolvedAny1`
    /// (which is set when a wildcard edge was taken during the lookup).
    func outputValue(state: State) -> [Character]? {
        switch self {
        case .node(let output, _, _, _, _):
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
                    case .key(let intention, let input, _): intention ?? input
                    case .compositionSeparator, nil: nil
                    }
                }
            }
        }
    }
}

public struct InputTable: Sendable {
    public static let empty = InputTable(baseMapping: [:])
    public static let defaultRomanToKana = InputTable(baseMapping: InputTables.defaultRomanToKanaPieceMap)
    public static let defaultAZIK = InputTable(baseMapping: InputTables.defaultAzikPieceMap)
    public static let defaultKanaJIS = InputTable(baseMapping: InputTables.defaultKanaJISPieceMap)
    public static let defaultKanaUS = InputTable(baseMapping: InputTables.defaultKanaUSPieceMap)

    /// Suffix‑oriented trie used for O(m) longest‑match lookup.
    public enum KeyElement: Sendable, Equatable, Hashable {
        case piece(InputPiece)
        case any1
    }

    public enum ValueElement: Sendable, Equatable, Hashable {
        case character(Character)
        case any1
    }

    @_disfavoredOverload
    public init(baseMapping: [[KeyElement]: [ValueElement]]) {
        self.init(baseMapping: .init(uniqueKeysWithValues: baseMapping))
    }

    init(baseMapping: OrderedDictionary<[KeyElement], [ValueElement]>) {
        self.baseMapping = baseMapping
        self.unstableSuffixes = baseMapping.keys.flatMapSet { pieces in
            pieces.indices.map { i in
                pieces[...i].compactMap { element in
                    if case let .piece(piece) = element, case let .character(c) = piece { c } else { nil }
                }
            }
        }
        let katakanaChanges: [String: String] = Dictionary(uniqueKeysWithValues: baseMapping.compactMap { key, value -> (String, String)? in
            let chars = key.compactMap { element -> Character? in
                if case let .piece(piece) = element, case let .character(c) = piece { c } else { nil }
            }
            guard chars.count == key.count else { return nil }
            let valueChars = value.compactMap {
                if case let .character(c) = $0 { c } else { nil }
            }
            return (String(chars), String(valueChars).toKatakana())
        })
        self.maxKeyCount = baseMapping.keys.map { $0.count }.max() ?? 0
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
        var root: TrieNode = .node(output: nil, charChildren: [:], separatorChild: nil, any1Child: nil, keyChildren: [:])
        for (key, value) in baseMapping {
            root.add(reversedKey: key.reversed().map { $0 }, output: value)
        }
        self.trieRoot = root
        self.maxUnstableSuffixLength = self.unstableSuffixes.map { $0.count }.max() ?? 0
    }

    let baseMapping: OrderedDictionary<[KeyElement], [ValueElement]>
    let unstableSuffixes: Set<[Character]>
    // Fast bound to avoid scanning entire set when checking suffixes
    let maxUnstableSuffixLength: Int
    let maxKeyCount: Int
    let possibleNexts: [String: [String]]

    /// Root of the suffix‑trie built from `pieceHiraganaChanges`.
    private let trieRoot: TrieNode

    // Helper: return the child node for `elem`, if it exists.
    private static func childCharacter(of node: TrieNode, _ c: Character) -> TrieNode? {
        switch node { case .node(_, let charChildren, _, _, _): return charChildren[c] }
    }

    private static func childSeparator(of node: TrieNode) -> TrieNode? {
        switch node { case .node(_, _, let separatorChild, _, _): return separatorChild }
    }

    private static func childKey(of node: TrieNode, input: Character, modifiers: Set<InputPiece.Modifier>) -> TrieNode? {
        switch node {
        case .node(_, _, _, _, let keyChildren):
            return keyChildren[.init(input: input, modifiers: modifiers)]
        }
    }

    private static func childAny1(of node: TrieNode) -> TrieNode? {
        switch node { case .node(_, _, _, let any1Child, _): return any1Child }
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
            var keyExact: Int
        }
        var best: (node: TrieNode, state: TrieNode.State, depth: Int, any1: Int, keyExact: Int)?

        @inline(__always) func better(_ cand: (depth: Int, any1: Int, keyExact: Int), than cur: (depth: Int, any1: Int, keyExact: Int)?) -> Bool {
            guard let cur else {
                return true
            }
            // Compare by: depth (max), fewer any1, more keyExact
            return cand.depth > cur.depth || (cand.depth == cur.depth && (cand.any1 < cur.any1 || (cand.any1 == cur.any1 && cand.keyExact > cur.keyExact)))
        }
        @inline(__always)
        func consider(_ node: TrieNode, _ state: TrieNode.State, _ depth: Int, _ any1: Int, _ keyExact: Int, _ stack: inout [Frame]) {
            if node.hasOutput {
                if better((depth: depth, any1: any1, keyExact: keyExact), than: best.map { (depth: $0.depth, any1: $0.any1, keyExact: $0.keyExact) }) {
                    best = (node, state, depth, any1, keyExact)
                }
            }
            stack.append(.init(node: node, state: state, depth: depth, any1: any1, keyExact: keyExact))
        }
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

        var stack: [Frame] = [.init(node: root, state: .init(), depth: 0, any1: 0, keyExact: 0)]
        stack.reserveCapacity(max(2, maxKeyCount))

        while let top = stack.popLast() {
            guard top.depth < maxKeyCount, let piece = pieceAt(top.depth) else {
                continue
            }
            // 1) Concrete edges
            switch piece {
            case .character(let c):
                if let next = childCharacter(of: top.node, c) {
                    consider(next, top.state, top.depth + 1, top.any1, top.keyExact, &stack)
                }
            case .compositionSeparator:
                if let next = childSeparator(of: top.node) {
                    consider(next, top.state, top.depth + 1, top.any1, top.keyExact, &stack)
                }
            case .key(let intention, let input, let modifiers):
                let ch = intention ?? input
                // Prefer character rule on actual input (B), then exact key rule.
                if let next = childCharacter(of: top.node, ch) {
                    consider(next, top.state, top.depth + 1, top.any1, top.keyExact, &stack)
                }
                if let next = childKey(of: top.node, input: ch, modifiers: modifiers) {
                    consider(next, top.state, top.depth + 1, top.any1, top.keyExact + 1, &stack)
                }
            }

            // 2) `.any1` fallback (only if compatible)
            if (top.state.resolvedAny1 ?? piece) == piece, let nextAny = childAny1(of: top.node) {
                var newState = top.state
                if newState.resolvedAny1 == nil {
                    newState.resolvedAny1 = piece
                }
                consider(nextAny, newState, top.depth + 1, top.any1 + 1, top.keyExact, &stack)
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
    func applied(currentText: [Character], added: InputPiece) -> [Character] {
        var currentText = currentText
        self.apply(to: &currentText, added: added)
        return currentText
    }

    /// In‑place variant: mutates `buffer` and returns deleted count.
    /// Semantics match `toHiragana(currentText:added:)` but avoids new allocations
    /// when possible by editing the tail of `buffer` directly.
    @discardableResult
    borrowing func apply(to buffer: inout [Character], added: InputPiece) -> Int {
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
            return deleteCount
        }

        switch added {
        case .character(let ch):
            buffer.append(ch)
        case .compositionSeparator:
            break
        case .key(let intention, let input, _):
            buffer.append(intention ?? input)
        }
        return 0
    }
}

public extension InputTable {
    enum Ordering {
        case lastInputWins
    }
    init(tables: [InputTable], order: Ordering) {
        var map: OrderedDictionary<[KeyElement], [ValueElement]> = [:]
        switch order {
        case .lastInputWins:
            for table in tables {
                for (k, v) in table.baseMapping {
                    map[k] = v
                }
            }
        }
        self.init(baseMapping: map)
    }
}
