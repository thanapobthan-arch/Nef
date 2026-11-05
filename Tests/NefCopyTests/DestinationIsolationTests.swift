import XCTest
@testable import NefCopy

final class DestinationIsolationTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopyIsolation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func setup()throws->(CopyEngine,URL,URL,URL) {
        let s=root.appendingPathComponent("source.bin"),a=root.appendingPathComponent("healthy"),b=root.appendingPathComponent("other")
        try Data(repeating:0xa5,count:32*1024*1024).write(to:s)
        for d in [a,b] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)}
        let e=CopyEngine();e.sourceURLs=[s];e.addDestinationURL(a);e.addDestinationURL(b)
        return(e,s,a,b)
    }
    private func wait(_ timeout:Double=15,_ condition:()->Bool) {
        let end=Date().addingTimeInterval(timeout)
        while !condition() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
        XCTAssertTrue(condition(),"Timed out")
    }
    private func assertGood(_ s:URL,_ d:URL)throws {
        XCTAssertEqual(try Data(contentsOf:s),try Data(contentsOf:d.appendingPathComponent(s.lastPathComponent)))
    }
    private func assertNoPartials(_ d:URL) {
        let paths=(FileManager.default.enumerator(at:d,includingPropertiesForKeys:nil)?.allObjects as? [URL]) ?? []
        XCTAssertFalse(paths.contains{$0.lastPathComponent.hasPrefix(".nefcopy-partial-")})
    }
    func testSlowDestinationDoesNotDelayHealthyVerifiedCopyOrLog()throws {
        let(e,s,a,b)=try setup();e.testDestinationWriteDelays[b.path]=0.15;e.start()
        wait{e.destinationProgress.contains{$0.path==a.path && $0.verified}}
        XCTAssertTrue(e.isRunning)
        let row=try XCTUnwrap(e.destinationProgress.first{$0.path==a.path})
        XCTAssertNotNil(row.report);XCTAssertTrue(FileManager.default.fileExists(atPath:try XCTUnwrap(row.report).path))
        try assertGood(s,a)
        wait{!e.isRunning};XCTAssertEqual(e.state,.completed);XCTAssertTrue(e.lastRunWasVerified)
        try assertGood(s,b)
    }
    func testWriteFailureDoesNotCancelOtherDestination()throws {
        let(e,s,a,b)=try setup();e.testDestinationFailureBytes[b.path]=8*1024*1024;e.start()
        wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.lastRunWasVerified);XCTAssertFalse(e.canSafeEject)
        XCTAssertEqual(e.passCount,1);XCTAssertEqual(e.failCount,1)
        try assertGood(s,a);XCTAssertFalse(FileManager.default.fileExists(atPath:b.appendingPathComponent(s.lastPathComponent).path))
        assertNoPartials(a);assertNoPartials(b)
        XCTAssertTrue(e.destinationProgress.contains{$0.path==a.path && $0.verified})
    }
    func testRetryFailedDestinationsPreservesHealthyCopy()throws {
        let(e,s,a,b)=try setup();e.testDestinationFailureBytes[b.path]=0;e.start();wait{!e.isRunning}
        XCTAssertTrue(e.canRetryFailed)
        let target=a.appendingPathComponent(s.lastPathComponent)
        let before=try FileManager.default.attributesOfItem(atPath:target.path)[.modificationDate] as? Date
        e.testDestinationFailureBytes=[:];e.retryFailed();wait{!e.isRunning}
        XCTAssertEqual(e.state,.completed);XCTAssertTrue(e.lastRunWasVerified)
        XCTAssertEqual(e.destinationProgress.map{$0.path},[b.path])
        XCTAssertFalse(e.canSafeEject,"A retry-only run must not certify destinations it did not revalidate")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:target.path)[.modificationDate] as? Date,before)
        try assertGood(s,a);try assertGood(s,b)
    }
    func testDisconnectCancelsOnlySelectedDestination()throws {
        let(e,s,a,b)=try setup();e.testDestinationWriteDelays[b.path]=0.1;e.start()
        wait{e.copiedBytes>0}
        e.testDisconnectDestination(b);wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.canSafeEject)
        try assertGood(s,a);assertNoPartials(b)
        XCTAssertTrue(e.destinationProgress.contains{$0.path==b.path && $0.state=="Disconnected"})
    }
    func testMissingDestinationFolderIsNotRecreated()throws {
        let(e,s,a,b)=try setup();e.testDestinationWriteDelays[b.path]=0.1;e.start()
        wait{e.copiedBytes>0}
        try FileManager.default.removeItem(at:b)
        wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);try assertGood(s,a)
        XCTAssertFalse(FileManager.default.fileExists(atPath:b.path))
    }
    func testPauseStillWorksAfterAnotherDestinationFails()throws {
        let(e,s,a,b)=try setup();e.testDestinationWriteDelays[a.path]=0.1;e.testDestinationFailureBytes[b.path]=0;e.start()
        wait{e.errorMessage != nil && e.isRunning}
        e.pauseTransfer();XCTAssertTrue(e.isPaused)
        let settle=Date().addingTimeInterval(0.2)
        while Date()<settle {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
        let bytes=e.copiedBytes,hold=Date().addingTimeInterval(0.15)
        while Date()<hold {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
        XCTAssertEqual(e.copiedBytes,bytes)
        e.resumeTransfer();wait{!e.isRunning};XCTAssertEqual(e.state,.failed);try assertGood(s,a)
    }
    func testLaggingDestinationRejectsSourceChangedAfterPlanning()throws {
        let(e,s,a,b)=try setup();let original=try Data(contentsOf:s)
        let gate=DispatchSemaphore(value:0)
        e.testDestinationBeforeCopy[b.path]={_ in _=gate.wait(timeout:.now()+10)}
        e.start();wait{e.destinationProgress.contains{$0.path==a.path && $0.verified}}
        XCTAssertEqual(try Data(contentsOf:a.appendingPathComponent(s.lastPathComponent)),original)
        try Data(repeating:0x42,count:original.count).write(to:s)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(2)],ofItemAtPath:s.path)
        gate.signal();wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.canSafeEject)
        XCTAssertFalse(FileManager.default.fileExists(atPath:b.appendingPathComponent(s.lastPathComponent).path))
        XCTAssertEqual(try Data(contentsOf:a.appendingPathComponent(s.lastPathComponent)),original)
    }
    func testSourceDisconnectStopsAllDestinationWorkers()throws {
        let(e,_,a,b)=try setup();e.testCopyDelayPerChunk=0.1;e.start();wait{e.copiedBytes>0}
        e.testDisconnectSource();wait{!e.isRunning}
        XCTAssertEqual(e.state,.cancelled);XCTAssertFalse(e.canSafeEject)
        XCTAssertTrue(e.statusText.contains("Source Disconnected"));assertNoPartials(a);assertNoPartials(b)
    }
    func testCancelStopsAndDrainsAllDestinationWorkers()throws {
        let(e,_,a,b)=try setup();e.testCopyDelayPerChunk=0.1;e.start();wait{e.copiedBytes>0}
        e.cancel();wait{!e.isRunning}
        XCTAssertEqual(e.state,.cancelled);XCTAssertFalse(e.canSafeEject);assertNoPartials(a);assertNoPartials(b)
    }
}
