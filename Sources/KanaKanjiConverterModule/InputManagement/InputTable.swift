import SwiftUtils
private indirect enum TrieNode {
    struct State: Sendable, Equatable, Hashable {
        var resolvedAny1: InputPiece?
    }

    case node(output: [InputTable.ValueElement]?, children: [InputTable.KeyElement: TrieNode] = [:])

    // Recursively insert a reversed key path and set the output when the path ends.
    mutating func add(reversedKey: some Collection<InputTable.KeyElement>, output: [InputTable.ValueElement]) {
        guard let head = reversedKey.first else {
            // Reached the end of the key; store kana
            switch self {
            case let .node(_, children):
                self = .node(output: output, children: children)
            }
            return
        }
        let rest = reversedKey.dropFirst()
        switch self {
        case .node(let currentOutput, var children):
            var child = children[head] ?? .node(output: nil, children: [:])
            child.add(reversedKey: rest, output: output)
            children[head] = child
            self = .node(output: currentOutput, children: children)
        }
    }

    /// Returns the kana sequence stored at this node, resolving `.any1`
    /// placeholders in the *output* side using `state.resolvedAny1`
    /// (which is set when a wildcard edge was taken during the lookup).
    func outputValue(state: State) -> [SurfacePiece]? {
        switch self {
        case .node(let output, _):
            output?.compactMap { elem in
                switch elem {
                case .piece(let piece): piece
                case .any1:
                    // Replace `.any1` with the character captured when a
                    // wildcard edge was followed. If none is available,
                    // we return the NUL character so the caller can treat
                    // it as an invalid match.
                    switch state.resolvedAny1 {
                    case .character(let c): .character(c)
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
        case piece(SurfacePiece)
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
                if case let .piece(piece) = $0, case let .character(c) = piece { c } else { nil }
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
        var root: TrieNode = .node(output: nil, children: [:])
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
    private static func child(of node: TrieNode, _ elem: KeyElement) -> TrieNode? {
        switch node {
        case .node(_, let children): children[elem]
        }
    }

    // Helper: breadth‑first search that explores both concrete and
    // `.any1` edges at each depth.  It keeps the deepest match; when
    // multiple matches share the same depth, the one that travelled
    // through fewer `.any1` edges is preferred.
    private static func match(root: TrieNode, pieces: [InputPiece], maxKeyCount: Int) -> ([SurfacePiece], Int)? {
        struct Candidate {
            var node: TrieNode
            var state: TrieNode.State
            var any1Count: Int
        }

        var frontier: [Candidate] = [.init(node: root, state: .init(), any1Count: 0)]
        var best: (kana: [SurfacePiece], depth: Int, any1Count: Int)?

        /// Update the current `best` candidate if the new one is deeper,
        /// or at the same depth but with fewer `.any1` hops.
        func updateBest(_ kana: [SurfacePiece], _ depth: Int, _ any1Count: Int) {
            if best == nil ||
                depth > best!.depth ||
                (depth == best!.depth && any1Count < best!.any1Count) {
                best = (kana, depth, any1Count)
            }
        }

        for (i, piece) in pieces.enumerated() where !frontier.isEmpty && i < maxKeyCount {
            var nextFrontier: [Candidate] = []
            defer {
                frontier = nextFrontier
            }

            for cand in frontier {
                // 1. Concrete edge
                if let next = child(of: cand.node, .piece(piece)) {
                    var c = cand
                    c.node = next
                    nextFrontier.append(c)
                    if let kana = next.outputValue(state: c.state) {
                        updateBest(kana, i + 1, c.any1Count)
                    }
                }

                // 2. `.any1` edge
                if (cand.state.resolvedAny1 ?? piece) == piece,
                   let next = child(of: cand.node, .any1) {
                    let c = Candidate(node: next, state: .init(resolvedAny1: piece), any1Count: cand.any1Count + 1)
                    nextFrontier.append(c)
                    if let kana = next.outputValue(state: c.state) {
                        updateBest(kana, i + 1, c.any1Count)
                    }
                }
            }
        }

        return best.map { ($0.kana, $0.depth) }
    }

    /// Convert roman/katakana input pieces into hiragana.
    /// `any1` edges serve strictly as fall‑backs: a concrete `.piece`
    /// transition always has priority and we only follow `.any1`
    /// when no direct edge exists at the same depth.
    ///
    /// The algorithm walks the suffix‑trie from the newly added piece
    /// backwards, examining at most `maxKeyCount` pieces, and keeps the
    /// longest match.
    func updateSurface(current: [SurfacePiece], added: InputPiece) -> [SurfacePiece] {
        // Build the sequence to inspect: the newly‑added piece followed by up to
        // `maxKeyCount‑1` characters from the tail of `currentText`, in reverse.
        let pieces: [InputPiece] = [added] + current.suffix(max(0, self.maxKeyCount - 1)).reversed().map {
            switch $0 {
            case .character(let c): .character(c)
            case .surfaceSeparator: .compositionSeparator
            }
        }

        // Use the breadth‑first match.
        let bestMatch = Self.match(root: self.trieRoot, pieces: pieces, maxKeyCount: self.maxKeyCount)

        // Apply the result or fall back to passthrough behaviour.
        if let (kana, matchedDepth) = bestMatch {
            // `matchedDepth` includes `added`, so drop `matchedDepth - 1` chars.
            return Array(current.dropLast(matchedDepth - 1)) + kana
        }

        // In case where no match found
        switch added {
        case .character(let ch):
            return current + [.character(ch)]
        case .compositionSeparator:
            return current
        }
    }
}
