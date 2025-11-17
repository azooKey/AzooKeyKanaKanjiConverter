import Dispatch
import XCTest

@MainActor
class MainActorTestCase: XCTestCase {
    override func invokeTest() {
        if Thread.isMainThread {
            super.invokeTest()
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            super.invokeTest()
            semaphore.signal()
        }
        semaphore.wait()
    }
}
