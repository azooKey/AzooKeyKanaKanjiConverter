import HeapModule

struct FixedSizeHeap<Element: Comparable> {
    private var size: Int
    private var heap: Heap<Element>

    init(size: Int) {
        self.size = size
        self.heap = []
    }

    mutating func removeMax() {
        self.heap.removeMax()
    }

    mutating func removeMin() {
        self.heap.removeMin()
    }

    @discardableResult
    mutating func insertIfPossible(_ element: Element) -> Bool {
        if self.heap.count < self.size {
            self.heap.insert(element)
            return true
        } else if let min = self.heap.min, element > min {
            self.heap.replaceMin(with: element)
            return true
        } else {
            return false
        }
    }

    var unordered: [Element] {
        self.heap.unordered
    }

    var max: Element? {
        self.heap.max
    }

    var min: Element? {
        self.heap.min
    }

    var isEmpty: Bool {
        self.heap.isEmpty
    }
}
