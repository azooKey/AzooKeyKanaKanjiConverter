import Foundation
import Synchronization

/// Thread-safe wrapper around `DicdataStore` using a standard library mutex.
final class LockedDicdataStore {
    private let store: Mutex<DicdataStore>

    init(requestOptions: ConvertRequestOptions = .default) {
        self.store = Mutex(DicdataStore(requestOptions: requestOptions))
    }

    var maxlength: Int { store.withLock { $0.maxlength } }

    func send(_ notification: DicdataStore.Notification) {
        store.withLock { $0.sendToDicdataStore(notification) }
    }

    func getLOUDSDataInRange(inputData: ComposingText, from fromIndex: Int, toIndexRange: Range<Int>? = nil, needTypoCorrection: Bool = true) -> [LatticeNode] {
        return store.withLock { $0.getLOUDSDataInRange(inputData: inputData, from: fromIndex, toIndexRange: toIndexRange, needTypoCorrection: needTypoCorrection) }
    }

    func getLOUDSData(inputData: ComposingText, from fromIndex: Int, to toIndex: Int, needTypoCorrection: Bool) -> [LatticeNode] {
        return store.withLock { $0.getLOUDSData(inputData: inputData, from: fromIndex, to: toIndex, needTypoCorrection: needTypoCorrection) }
    }

    func getPredictionLOUDSDicdata(key: some StringProtocol) -> [DicdataElement] {
        return store.withLock { $0.getPredictionLOUDSDicdata(key: key) }
    }

    func getPrefixMatchDynamicUserDict(_ ruby: some StringProtocol) -> [DicdataElement] {
        return store.withLock { $0.getPrefixMatchDynamicUserDict(ruby) }
    }

    func getZeroHintPredictionDicdata(lastRcid: Int) -> [DicdataElement] {
        return store.withLock { $0.getZeroHintPredictionDicdata(lastRcid: lastRcid) }
    }

    func getCCValue(_ former: Int, _ latter: Int) -> PValue {
        return store.withLock { $0.getCCValue(former, latter) }
    }

    func getMMValue(_ former: Int, _ latter: Int) -> PValue {
        return store.withLock { $0.getMMValue(former, latter) }
    }

    func shouldBeRemoved(data: borrowing DicdataElement) -> Bool {
        return store.withLock { $0.shouldBeRemoved(data: data) }
    }

    func updateLearningData(_ candidate: Candidate, with previous: DicdataElement?) {
        store.withLock { $0.updateLearningData(candidate, with: previous) }
    }

    func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        store.withLock { $0.updateLearningData(candidate, with: predictionCandidate) }
    }
}
