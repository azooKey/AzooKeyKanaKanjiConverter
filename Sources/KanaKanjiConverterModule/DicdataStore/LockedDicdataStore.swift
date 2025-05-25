import Foundation

/// Thread-safe wrapper around `DicdataStore` using `NSLock`.
///
/// `Mutex.withLock` is only available on newer OS versions, so
/// we use `NSLock` to support older platforms.
final class LockedDicdataStore {
    private var store: DicdataStore
    private let lock = NSLock()

    init(requestOptions: ConvertRequestOptions = .default) {
        self.store = DicdataStore(requestOptions: requestOptions)
    }

    var maxlength: Int { store.maxlength }

    func send(_ notification: DicdataStore.Notification) {
        lock.lock(); defer { lock.unlock() }
        store.sendToDicdataStore(notification)
    }

    func getLOUDSDataInRange(inputData: ComposingText, from fromIndex: Int, toIndexRange: Range<Int>? = nil, needTypoCorrection: Bool = true) -> [LatticeNode] {
        lock.lock(); defer { lock.unlock() }
        return store.getLOUDSDataInRange(inputData: inputData, from: fromIndex, toIndexRange: toIndexRange, needTypoCorrection: needTypoCorrection)
    }

    func getLOUDSData(inputData: ComposingText, from fromIndex: Int, to toIndex: Int, needTypoCorrection: Bool) -> [LatticeNode] {
        lock.lock(); defer { lock.unlock() }
        return store.getLOUDSData(inputData: inputData, from: fromIndex, to: toIndex, needTypoCorrection: needTypoCorrection)
    }

    func getPredictionLOUDSDicdata(key: some StringProtocol) -> [DicdataElement] {
        lock.lock(); defer { lock.unlock() }
        return store.getPredictionLOUDSDicdata(key: key)
    }

    func getPrefixMatchDynamicUserDict(_ ruby: some StringProtocol) -> [DicdataElement] {
        lock.lock(); defer { lock.unlock() }
        return store.getPrefixMatchDynamicUserDict(ruby)
    }

    func getZeroHintPredictionDicdata(lastRcid: Int) -> [DicdataElement] {
        lock.lock(); defer { lock.unlock() }
        return store.getZeroHintPredictionDicdata(lastRcid: lastRcid)
    }

    func getCCValue(_ former: Int, _ latter: Int) -> PValue {
        lock.lock(); defer { lock.unlock() }
        return store.getCCValue(former, latter)
    }

    func getMMValue(_ former: Int, _ latter: Int) -> PValue {
        lock.lock(); defer { lock.unlock() }
        return store.getMMValue(former, latter)
    }

    func shouldBeRemoved(data: borrowing DicdataElement) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store.shouldBeRemoved(data: data)
    }

    func updateLearningData(_ candidate: Candidate, with previous: DicdataElement?) {
        lock.lock(); defer { lock.unlock() }
        store.updateLearningData(candidate, with: previous)
    }

    func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        lock.lock(); defer { lock.unlock() }
        store.updateLearningData(candidate, with: predictionCandidate)
    }
}
