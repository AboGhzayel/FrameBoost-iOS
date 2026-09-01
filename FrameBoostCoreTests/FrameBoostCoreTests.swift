import XCTest
@testable import FrameBoostCore

final class FrameBoostCoreTests: XCTestCase {
    func testVersionIsPresent() {
        XCTAssertFalse(FrameBoostCore.version.isEmpty)
    }

    func testCoreCanBeInitialized() {
        _ = FrameBoostCore()
    }
}
