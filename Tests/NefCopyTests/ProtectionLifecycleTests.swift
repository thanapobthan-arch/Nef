import XCTest
@testable import NefCopy
final class ProtectionLifecycleTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("NefProtection-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try FileManager.default.removeItem(at:root)}
    private func wait(_ predicate:()->Bool) {let deadline=Date().addingTimeInterval(15);while !predicate() && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.005))};XCTAssertTrue(predicate())}
    private func engine()throws->CopyEngine {
        let source=root.appendingPathComponent("new.bin"),destination=root.appendingPathComponent("out")
        try Data(repeating:71,count:32*1024*1024).write(to:source);try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        let e=CopyEngine();e.sourceURLs=[source];e.destinations=[Destination(url:destination)];e.transferStrategy = .standard;e.testCopyDelayPerChunk=0.05
        return e
    }
    func testTestHistoryNeverUsesTheRealApplicationHistory() {
        let path=CopyEngine().testLocalHistoryDirectory.path
        XCTAssertFalse(path.contains("Library/Application Support/NefCopy"))
        XCTAssertTrue(path.hasPrefix("/private/") || path.hasPrefix("/var/"))
    }
    func testNoSpaceRejectsPreflightAndDirectStartWithoutPublishingMedia()throws {
        let e=try engine();e.testAvailableBytes=0;var result:PreflightResult?
        e.runPreflight{result=$0};wait{result != nil};XCTAssertFalse(result!.ok)
        e.start();wait{!e.isRunning};XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.lastRunWasVerified)
        XCTAssertFalse(FileManager.default.fileExists(atPath:e.destinations[0].url.appendingPathComponent("new.bin").path));XCTAssertFalse(e.testSleepPreventionActive)
    }
    func testIdleSleepAssertionIsAcquiredAndReleasedAfterVerifiedCompletion()throws {
        let e=try engine();e.start();wait{e.testSleepPreventionActive};XCTAssertTrue(e.isRunning)
        wait{!e.isRunning};XCTAssertTrue(e.lastRunWasVerified);XCTAssertFalse(e.testSleepPreventionActive)
    }
    func testCancellationDrainsAndReleasesIdleSleepAssertion()throws {
        let e=try engine();e.start();wait{e.testSleepPreventionActive && e.copiedBytes>0};e.cancel()
        wait{!e.isRunning};XCTAssertFalse(e.lastRunWasVerified);XCTAssertFalse(e.testSleepPreventionActive)
    }
}
