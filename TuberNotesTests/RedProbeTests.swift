import XCTest

// THROWAWAY. Plants a failing assertion so ci.yml can be observed going red.
// A verdict that has never been contradicted is decoration — CONTRIBUTING.md,
// "Rules for any check you add". This file and its branch are deleted once the
// red run has been read on the run page.
final class RedProbeTests: XCTestCase {
    func testCIActuallyFailsWhenATestFails() {
        XCTAssertEqual(1, 2, "deliberate failure planted to prove ci.yml goes red")
    }
}
