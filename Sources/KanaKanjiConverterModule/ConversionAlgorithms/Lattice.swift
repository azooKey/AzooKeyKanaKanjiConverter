import Algorithms
import SwiftUtils

struct LatticeNodeArray: Sequence {
    typealias Element = LatticeNode

    var inputIndexedNodes: [LatticeNode]
    var surfaceIndexedNodes: [LatticeNode]

    func makeIterator() -> Chain2Sequence<[LatticeNode], [LatticeNode]>.Iterator {
        inputIndexedNodes.chained(surfaceIndexedNodes).makeIterator()
    }
}

struct LatticeDualIndexMap: Sendable {
    private var inputIndexToSurfaceIndexMap: [Int: Int]
    init(_ composingText: ComposingText) {
        self.inputIndexToSurfaceIndexMap = composingText.inputIndexToSurfaceIndexMap()
    }

    enum DualIndex: Sendable, Equatable, Hashable {
        case inputIndex(Int)
        case surfaceIndex(Int)
        case bothIndex(inputIndex: Int, surfaceIndex: Int)

        var inputIndex: Int? {
            switch self {
            case .inputIndex(let index), .bothIndex(let index, _):
                index
            case .surfaceIndex:
                nil
            }
        }

        var surfaceIndex: Int? {
            switch self {
            case .inputIndex:
                nil
            case .surfaceIndex(let index), .bothIndex(_, let index):
                index
            }
        }
    }

    func dualIndex(for latticeIndex: Lattice.LatticeIndex) -> DualIndex {
        switch latticeIndex {
        case .input(let iIndex):
            if let sIndex = self.inputIndexToSurfaceIndexMap[iIndex] {
                .bothIndex(inputIndex: iIndex, surfaceIndex: sIndex)
            } else {
                .inputIndex(iIndex)
            }
        case .surface(let sIndex):
            if let iIndex = self.inputIndexToSurfaceIndexMap.filter({ $0.value == sIndex}).first?.key {
                .bothIndex(inputIndex: iIndex, surfaceIndex: sIndex)
            } else {
                .surfaceIndex(sIndex)
            }
        }
    }

    func indices(inputCount: Int, surfaceCount: Int) -> [DualIndex] {
        var indices: [DualIndex] = []
        var sIndexPointer = 0
        for i in 0 ..< inputCount {
            if let sIndex = self.inputIndexToSurfaceIndexMap[i] {
                for j in min(sIndexPointer, sIndex) ..< sIndex {
                    indices.append(.surfaceIndex(j))
                }
                if sIndexPointer <= sIndex, sIndex < surfaceCount {
                    indices.append(.bothIndex(inputIndex: i, surfaceIndex: sIndex))
                } else {
                    indices.append(.inputIndex(i))
                }
                sIndexPointer = sIndex + 1
            } else {
                indices.append(.inputIndex(i))
            }
        }
        for j in min(surfaceCount, sIndexPointer) ..< surfaceCount {
            indices.append(.surfaceIndex(j))
        }
        return indices
    }
}

struct Lattice: Sequence {
    typealias Element = LatticeNodeArray

    init() {
        self.inputIndexedNodes = []
        self.surfaceIndexedNodes = []
    }

    init(inputCount: Int, surfaceCount: Int, rawNodes: [[LatticeNode]]) {
        self.inputIndexedNodes = .init(repeating: [], count: inputCount)
        self.surfaceIndexedNodes = .init(repeating: [], count: surfaceCount)

        for nodes in rawNodes {
            guard let first = nodes.first else { continue }
            switch first.range.startIndex {
            case .surface(let i):
                self.surfaceIndexedNodes[i].append(contentsOf: nodes)
            case .input(let i):
                self.inputIndexedNodes[i].append(contentsOf: nodes)
            }
        }
    }

    private init(inputIndexedNodes: [[LatticeNode]], surfaceIndexedNodes: [[LatticeNode]]) {
        self.inputIndexedNodes = inputIndexedNodes
        self.surfaceIndexedNodes = surfaceIndexedNodes
    }

    private var inputIndexedNodes: [[LatticeNode]]
    private var surfaceIndexedNodes: [[LatticeNode]]

    func prefix(inputCount: Int, surfaceCount: Int) -> Lattice {
        let filterClosure: (LatticeNode) -> Bool = { (node: LatticeNode) -> Bool in
            switch node.range.endIndex {
            case .input(let value):
                value <= inputCount
            case .surface(let value):
                value <= surfaceCount
            }
        }
        let newInputIndexedNodes = self.inputIndexedNodes.prefix(inputCount).map {(nodes: [LatticeNode]) in
            nodes.filter(filterClosure)
        }
        let newSurfaceIndexedNodes = self.surfaceIndexedNodes.prefix(surfaceCount).map {(nodes: [LatticeNode]) in
            nodes.filter(filterClosure)
        }

        return Lattice(inputIndexedNodes: newInputIndexedNodes, surfaceIndexedNodes: newSurfaceIndexedNodes)
    }

    func suffix(inputCount: Int, surfaceCount: Int) -> Lattice {
        Lattice(
            inputIndexedNodes: self.inputIndexedNodes.suffix(inputCount),
            surfaceIndexedNodes: self.surfaceIndexedNodes.suffix(surfaceCount)
        )
    }

    mutating func merge(_ lattice: Lattice) {
        for (index, nodeArray) in lattice.inputIndexedNodes.enumerated() where index < self.inputIndexedNodes.endIndex {
            self.inputIndexedNodes[index].append(contentsOf: nodeArray)
        }
        if self.inputIndexedNodes.endIndex < lattice.inputIndexedNodes.endIndex {
            for nodeArray in lattice.inputIndexedNodes[self.inputIndexedNodes.endIndex...] {
                self.inputIndexedNodes.append(nodeArray)
            }
        }
        for (index, nodeArray) in lattice.surfaceIndexedNodes.enumerated() where index < self.surfaceIndexedNodes.endIndex {
            self.surfaceIndexedNodes[index].append(contentsOf: nodeArray)
        }
        if self.surfaceIndexedNodes.endIndex < lattice.surfaceIndexedNodes.endIndex {
            for nodeArray in lattice.surfaceIndexedNodes[self.surfaceIndexedNodes.endIndex...] {
                self.surfaceIndexedNodes.append(nodeArray)
            }
        }
    }

    func resetNodeStates() {
        // 探索で変化した状態をすべて削除する
        self.inputIndexedNodes.forEach { nodes in
            nodes.forEach {
                $0.prevs.removeAll()
                $0.values.removeAll()
                if $0.range.startIndex.isZero {
                    $0.prevs.append(.BOSNode())
                }
            }
        }
        self.surfaceIndexedNodes.forEach { nodes in
            nodes.forEach {
                $0.prevs.removeAll()
                $0.values.removeAll()
                if $0.range.startIndex.isZero {
                    $0.prevs.append(.BOSNode())
                }
            }
        }
    }

    subscript(index index: LatticeDualIndexMap.DualIndex) -> LatticeNodeArray {
        get {
            let iNodes: [LatticeNode] = if let iIndex = index.inputIndex { self.inputIndexedNodes[iIndex] } else { [] }
            let sNodes: [LatticeNode] = if let sIndex = index.surfaceIndex { self.surfaceIndexedNodes[sIndex] } else { [] }
            return LatticeNodeArray(inputIndexedNodes: iNodes, surfaceIndexedNodes: sNodes)
        }
    }

    func indexedNodes(indices: [LatticeDualIndexMap.DualIndex]) -> some Sequence<(isHead: Bool, nodes: LatticeNodeArray)> {
        indices.lazy.map { index in
            (index.inputIndex == 0 && index.surfaceIndex == 0, self[index: index])
        }
    }

    var inputNodeColumnsCount: Int {
        self.inputIndexedNodes.count
    }

    var surfaceNodeColumnsCount: Int {
        self.surfaceIndexedNodes.count
    }

    func forEachNode(_ body: (LatticeNode) -> Void) {
        self.inputIndexedNodes.forEach { column in
            column.forEach(body)
        }
        self.surfaceIndexedNodes.forEach { column in
            column.forEach(body)
        }
    }

    init(snapshot: LatticeSnapshot) {
        self.init()
        self.inputIndexedNodes = .init(repeating: [], count: snapshot.inputCount)
        self.surfaceIndexedNodes = .init(repeating: [], count: snapshot.surfaceCount)
        for snapshotNode in snapshot.nodes {
            let node = snapshotNode.makeNode()
            switch snapshotNode.range.startIndex {
            case .input(let index):
                guard self.inputIndexedNodes.indices.contains(index) else { continue }
                self.inputIndexedNodes[index].append(node)
            case .surface(let index):
                guard self.surfaceIndexedNodes.indices.contains(index) else { continue }
                self.surfaceIndexedNodes[index].append(node)
            }
        }
    }

    var totalNodeCount: Int {
        self.inputIndexedNodes.reduce(0) { $0 + $1.count } + self.surfaceIndexedNodes.reduce(0) { $0 + $1.count }
    }

    struct Iterator: IteratorProtocol {
        init(lattice: Lattice) {
            self.lattice = lattice
            self.indices = (0, lattice.surfaceIndexedNodes.endIndex, 0, lattice.inputIndexedNodes.endIndex)
        }

        typealias Element = LatticeNodeArray
        let lattice: Lattice
        var indices: (currentSurfaceIndex: Int, surfaceEndIndex: Int, currentInputIndex: Int, inputEndIndex: Int)

        mutating func next() -> LatticeNodeArray? {
            if self.indices.currentSurfaceIndex < self.indices.surfaceEndIndex {
                defer {
                    self.indices.currentSurfaceIndex += 1
                }
                return .init(inputIndexedNodes: [], surfaceIndexedNodes: self.lattice.surfaceIndexedNodes[self.indices.currentSurfaceIndex])
            } else if self.indices.currentInputIndex < self.indices.inputEndIndex {
                defer {
                    self.indices.currentInputIndex += 1
                }
                return .init(inputIndexedNodes: self.lattice.inputIndexedNodes[self.indices.currentInputIndex], surfaceIndexedNodes: [])
            } else {
                return nil
            }
        }
    }

    func makeIterator() -> Iterator {
        Iterator(lattice: self)
    }

    var isEmpty: Bool {
        self.inputIndexedNodes.isEmpty && self.surfaceIndexedNodes.isEmpty
    }

    enum LatticeIndex: Sendable, Equatable, Hashable {
        case surface(Int)
        case input(Int)

        var isZero: Bool {
            self == .surface(0) || self == .input(0)
        }
    }

    enum LatticeRange: Sendable, Equatable, Hashable {
        static var zero: Self {
            .input(from: 0, to: 0)
        }
        case surface(from: Int, to: Int)
        case input(from: Int, to: Int)

        var count: ComposingCount {
            switch self {
            case .surface(let from, let to):
                .surfaceCount(to - from)
            case .input(let from, let to):
                .inputCount(to - from)
            }
        }

        var startIndex: LatticeIndex {
            switch self {
            case .surface(let from, _):
                .surface(from)
            case .input(let from, _):
                .input(from)
            }
        }

        var endIndex: LatticeIndex {
            switch self {
            case .surface(_, let to):
                .surface(to)
            case .input(_, let to):
                .input(to)
            }
        }

        func offseted(inputOffset: Int, surfaceOffset: Int) -> Self {
            switch self {
            case .surface(from: let from, to: let to):
                .surface(from: from + surfaceOffset, to: to + surfaceOffset)
            case .input(from: let from, to: let to):
                .input(from: from + inputOffset, to: to + inputOffset)
            }
        }
    }
}

// MARK: - Sendable support
/// `Lattice` aggregates `LatticeNode` references that remain confined to the converter.
/// We rely on higher layers to avoid sharing it across actors until lattice snapshots land.
extension Lattice: @unchecked Sendable {}
