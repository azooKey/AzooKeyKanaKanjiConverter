import Dispatch
import XCTest

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

    func runOnMainActor<R>(_ block: @MainActor () throws -> R) rethrows -> R {
        if Thread.isMainThread {
            return try block()
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<R, Error>!
        Task { @MainActor in
            result = Result { try block() }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}
