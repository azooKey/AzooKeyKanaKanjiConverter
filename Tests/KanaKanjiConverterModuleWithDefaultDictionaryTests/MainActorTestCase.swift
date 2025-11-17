import Dispatch
import XCTest

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
@MainActor
class MainActorTestCase: XCTestCase {}
#else
// Linux XCTest doesn't support @MainActor on test methods
class MainActorTestCase: XCTestCase {}
#endif
