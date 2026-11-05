import XCTest
import CryptoKit
@testable import NefCopy
final class UIPolishTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("NefPolish-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try FileManager.default.removeItem(at:root)}
    private func wait(_ predicate:()->Bool) {let deadline=Date().addingTimeInterval(20);while !predicate() && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.005))};XCTAssertTrue(predicate())}
    private func settings(_ name:String,megabytes:Int=1)throws->TransferJobSettings {
        let s=root.appendingPathComponent(name),d=root.appendingPathComponent("out")
        for p in [s,d] {try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true)}
        try Data(repeating:11,count:megabytes*1024*1024).write(to:s.appendingPathComponent("new.bin"))
        return TransferJobSettings(sources:[s],destinations:[d],strategy:.standard)
    }
    func testClearQueueRemovesWaitingAndFinishedRowsButKeepsFilesAndReports()throws {
        let q=TransferQueue(storageURL:root.appendingPathComponent("queue.json"),startPaused:true),a=try settings("a"),b=try settings("b")
        q.enqueue(a);q.resumeQueue();wait{!q.isBusy};XCTAssertEqual(q.jobs[0].state,.verified)
        q.pauseQueue();q.enqueue(b)
        let copy=a.destinations[0].appendingPathComponent("a/new.bin"),before=try Data(contentsOf:copy),reports=q.jobs[0].reportURLs
        XCTAssertTrue(q.clearInactiveJobs());XCTAssertTrue(q.jobs.isEmpty);XCTAssertNil(q.displayedEngine)
        XCTAssertEqual(try Data(contentsOf:copy),before);XCTAssertTrue(reports.allSatisfy{FileManager.default.fileExists(atPath:$0.path)})
        let reopened=TransferQueue(storageURL:root.appendingPathComponent("queue.json"));XCTAssertTrue(reopened.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:b.destinations[0].appendingPathComponent("b/new.bin").path))
    }
    func testClearQueueDoesNotCancelOrReplaceActiveWorker()throws {
        let q=TransferQueue(storageURL:nil,startPaused:true,makeEngine:{_ in let e=CopyEngine();e.testCopyDelayPerChunk=0.05;return e})
        let first=q.enqueue(try settings("active",megabytes:32))!;q.enqueue(try settings("waiting"));q.resumeQueue();let worker=q.displayedEngine
        XCTAssertTrue(q.clearInactiveJobs());XCTAssertEqual(q.jobs.map{$0.id},[first]);XCTAssertTrue(q.displayedEngine === worker);XCTAssertEqual(q.activeJobID,first)
        wait{!q.isBusy};XCTAssertEqual(q.jobs[0].state,.verified)
    }
    func testClearQueueRollsBackWhenSnapshotCannotBeSaved()throws {
        let folder=root.appendingPathComponent("storage"),store=folder.appendingPathComponent("queue.json")
        let q=TransferQueue(storageURL:store,startPaused:true),id=q.enqueue(try settings("card"))!
        try FileManager.default.removeItem(at:folder);try Data([1]).write(to:folder)
        XCTAssertFalse(q.clearInactiveJobs());XCTAssertEqual(q.jobs.map{$0.id},[id]);XCTAssertNotNil(q.errorMessage)
    }
    func testClearHistoryIsDurableAndDoesNotRemoveReportsOrMedia()throws {
        let spec=try settings("history"),q=TransferQueue(storageURL:nil,startPaused:true);q.enqueue(spec);q.resumeQueue();wait{!q.isBusy}
        q.reloadTransferHistory();XCTAssertFalse(q.draft.history.isEmpty)
        let reports=q.jobs[0].reportURLs,copy=spec.destinations[0].appendingPathComponent("history/new.bin"),original=try Data(contentsOf:copy)
        try q.clearTransferHistory();XCTAssertTrue(q.draft.history.isEmpty);XCTAssertTrue(q.jobs[0].engine!.history.isEmpty)
        XCTAssertTrue(CopyEngine().history.isEmpty);XCTAssertEqual(try Data(contentsOf:copy),original)
        XCTAssertTrue(reports.allSatisfy{FileManager.default.fileExists(atPath:$0.path)});XCTAssertEqual(q.jobs.count,1)
    }
    func testClearHistoryIsBlockedWhileActive()throws {
        let q=TransferQueue(storageURL:nil,startPaused:true,makeEngine:{_ in let e=CopyEngine();e.testCopyDelayPerChunk=0.05;return e})
        q.enqueue(try settings("active",megabytes:32));q.resumeQueue()
        XCTAssertFalse(q.canClearTransferHistory);XCTAssertThrowsError(try q.clearTransferHistory())
        q.cancelAll();wait{!q.isBusy}
    }
    func testCleanPreflightStartsQueueWithoutReviewRoute()throws {
        let spec=try settings("clean"),q=TransferQueue(storageURL:nil,startPaused:true)
        q.draft.sourceURLs=spec.sources;q.draft.destinations=spec.destinations.map{Destination(url:$0)}
        var finished=false
        q.draft.runPreflight {result in
            XCTAssertFalse(PreflightRouting.requiresAttention(result));q.enqueueSourceBatch(TransferJobSettings(engine:q.draft));q.resumeQueue();finished=true
        }
        wait{finished && !q.isBusy && !q.hasPending};XCTAssertEqual(q.jobs.first?.state,.verified)
    }
    func testConflictingPreflightRequiresReviewAndCannotAutoStart()throws {
        let spec=try settings("conflict"),folder=spec.destinations[0].appendingPathComponent("conflict")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);let existing=folder.appendingPathComponent("new.bin");try Data("keep existing".utf8).write(to:existing)
        let q=TransferQueue(storageURL:nil);q.draft.sourceURLs=spec.sources;q.draft.destinations=spec.destinations.map{Destination(url:$0)};var finished=false
        q.draft.runPreflight {result in
            XCTAssertFalse(result.ok);XCTAssertTrue(PreflightRouting.requiresAttention(result));finished=true
        }
        wait{finished};XCTAssertTrue(q.jobs.isEmpty);XCTAssertEqual(try String(contentsOf:existing),"keep existing")
    }
    func testWarningsRequireReviewButPassAndSkipDoNot() {
        XCTAssertTrue(PreflightRouting.requiresAttention(PreflightResult(ok:true,messages:["WARNING — review"])))
        XCTAssertTrue(PreflightRouting.requiresAttention(PreflightResult(ok:false,messages:[])))
        XCTAssertFalse(PreflightRouting.requiresAttention(PreflightResult(ok:true,messages:["PASS — ready","SKIP — already verified"])))
    }
}
