import Dispatch
import XCTest

@MainActor
class MainActorTestCase: XCTestCase {
    override func invokeTest() {
        if Thread.isMainThread {
            super.invokeTest()
        } else {
            DispatchQueue.main.sync {
                super.invokeTest()
            }
        }
    }
}
