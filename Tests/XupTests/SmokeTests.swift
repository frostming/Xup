import XCTest
@testable import Xup

final class SmokeTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(VersionCompare.isNewer("1.5.0", than: "1.3.4"))
        XCTAssertFalse(VersionCompare.isNewer("1.0.0-beta", than: "1.0.0"))
    }
}
