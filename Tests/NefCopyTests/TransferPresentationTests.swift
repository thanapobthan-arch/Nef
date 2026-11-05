import XCTest
@testable import NefCopy

final class TransferPresentationTests: XCTestCase {
    func testOnlyVerifiedCompletionDisplaysOneHundredPercent() {
        for state in [JobState.idle, .copying, .verifying, .cancelled, .failed] {
            let ui = TransferPresentation(state: state, progress: 1, verified: false, hasError: false)
            XCTAssertLessThan(ui.percent, 100)
        }
        XCTAssertEqual(TransferPresentation(state: .completed, progress: 1, verified: true, hasError: false).percent, 100)
    }
    func testNonFiniteAndOutOfRangeProgressIsSafe() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(TransferPresentation(state: .copying, progress: value, verified: false, hasError: false).percent, 0)
        }
        XCTAssertEqual(TransferPresentation(state: .verifying, progress: 9, verified: false, hasError: false).percent, 99)
    }
    func testDisconnectHidesStaleSpeedEvenBeforeWorkerFinishes() {
        let ui = TransferPresentation(state: .verifying, progress: 0.76, verified: false, hasError: true)
        XCTAssertFalse(ui.showsLiveMetrics)
        XCTAssertTrue(ui.title.contains("Interrupted"))
        XCTAssertEqual(ui.percent, 76)
    }
    func testStoppedAndFailedJobsHideLiveMetrics() {
        for state in [JobState.cancelled, .failed, .completed] {
            XCTAssertFalse(TransferPresentation(state: state, progress: 0.5, verified: false, hasError: false).showsLiveMetrics)
        }
    }
    func testUnverifiedCompletionDoesNotClaimVerified() {
        let ui = TransferPresentation(state: .completed, progress: 1, verified: false, hasError: false)
        XCTAssertTrue(ui.title.contains("NOT VERIFIED"))
        XCTAssertLessThan(ui.percent, 100)
    }
    func testErrorOverridesCompletion() {
        let ui = TransferPresentation(state: .completed, progress: 1, verified: true, hasError: true)
        XCTAssertTrue(ui.title.contains("Interrupted"))
        XCTAssertLessThan(ui.percent, 100)
    }
}
