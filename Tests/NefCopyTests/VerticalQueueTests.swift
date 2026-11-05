import XCTest
import CryptoKit
import AppKit
@testable import NefCopy
final class VerticalQueueTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("NefVertical-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try FileManager.default.removeItem(at:root)}
    private func wait(_ condition:()->Bool) {let end=Date().addingTimeInterval(20);while !condition() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))};XCTAssertTrue(condition())}
    private func spec(_ index:Int,megabytes:Int=1)throws->TransferJobSettings {
        let source=root.appendingPathComponent("Card-\(index)"),a=root.appendingPathComponent("SSD-A"),b=root.appendingPathComponent("SSD-B")
        for p in [source,a,b] {try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true)}
        try Data(repeating:UInt8(index),count:megabytes*1024*1024).write(to:source.appendingPathComponent("new.bin"))
        try Data().write(to:source.appendingPathComponent("empty.bin"));try Data("ไทย & fixture".utf8).write(to:source.appendingPathComponent("ไทย.txt"))
        return TransferJobSettings(sources:[source],destinations:[a,b],independentSourceVerification:true)
    }
    func testSourceBatchSavesThreeJobsAndCopiesAllDestinationsWithSHA256()throws {
        let specs=try (1...3).map{try spec($0)},queue=TransferQueue(storageURL:root.appendingPathComponent("queue.json"),startPaused:true)
        let batch=TransferJobSettings(sources:specs.flatMap{$0.sources},destinations:specs[0].destinations,independentSourceVerification:true)
        let ids=queue.enqueueSourceBatch(batch);XCTAssertEqual(ids.count,3);XCTAssertFalse(queue.isBusy)
        let saved=TransferQueue(storageURL:root.appendingPathComponent("queue.json"));XCTAssertEqual(saved.jobs.map{$0.id},ids)
        // Start the restored snapshot only; the original queue remains paused.
        saved.resumeQueue();wait{!saved.isBusy && !saved.hasPending}
        XCTAssertTrue(saved.jobs.allSatisfy{$0.state == .verified});XCTAssertEqual(saved.jobs.count,3)
        for (index,job) in saved.jobs.enumerated() {
            XCTAssertEqual(job.settings.sources,specs[index].sources);XCTAssertEqual(job.engine?.independentSourceVerifiedFiles,3)
            if index>0 {XCTAssertGreaterThanOrEqual(job.startedAt!,saved.jobs[index-1].finishedAt!)}
            for file in try FileManager.default.contentsOfDirectory(at:specs[index].sources[0],includingPropertiesForKeys:nil) {
                for destination in job.settings.destinations {
                    let copy=destination.appendingPathComponent(specs[index].sources[0].lastPathComponent).appendingPathComponent(file.lastPathComponent)
                    XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:file)),SHA256.hash(data:try Data(contentsOf:copy)))
                }
            }
            XCTAssertEqual(job.reportURLs.count,2)
        }
    }
    func testDragReorderPersistsAndOnlyChangesWaitingSlots()throws {
        let store=root.appendingPathComponent("queue.json"),q=TransferQueue(storageURL:store,startPaused:true)
        let ids=try (1...4).map{q.enqueue(try spec($0))!}
        XCTAssertTrue(q.moveWaitingJob(ids[3],before:ids[1]));XCTAssertEqual(q.jobs.map{$0.id},[ids[0],ids[3],ids[1],ids[2]])
        XCTAssertTrue(q.moveWaitingJob(ids[0],before:nil));XCTAssertEqual(q.jobs.map{$0.id},[ids[3],ids[1],ids[2],ids[0]])
        let reopened=TransferQueue(storageURL:store);XCTAssertEqual(reopened.jobs.map{$0.id},q.jobs.map{$0.id});XCTAssertFalse(reopened.isBusy)
    }
    func testDragCannotMoveActiveJobOrTargetActiveRow()throws {
        let q=TransferQueue(storageURL:nil,startPaused:true,makeEngine:{_ in let e=CopyEngine();e.testCopyDelayPerChunk=0.04;return e})
        let first=q.enqueue(try spec(1,megabytes:32))!,second=q.enqueue(try spec(2))!,third=q.enqueue(try spec(3))!
        q.resumeQueue();q.pauseQueue();XCTAssertEqual(q.activeJobID,first)
        XCTAssertFalse(q.moveWaitingJob(first,before:second));XCTAssertFalse(q.moveWaitingJob(second,before:first))
        XCTAssertTrue(q.moveWaitingJob(third,before:second));XCTAssertEqual(q.activeJobID,first)
        q.cancelAll();wait{!q.isBusy}
    }
    func testDragDoesNotMoveCompletedPrefix()throws {
        let q=TransferQueue(storageURL:nil,startPaused:true);let a=q.enqueue(try spec(1))!,b=q.enqueue(try spec(2))!,c=q.enqueue(try spec(3))!
        q.resumeQueue();q.pauseQueue();wait{!q.isBusy};XCTAssertEqual(q.jobs[0].state,.verified)
        XCTAssertFalse(q.moveWaitingJob(a,before:b));XCTAssertTrue(q.moveWaitingJob(c,before:b));XCTAssertEqual(q.jobs.map{$0.id},[a,c,b])
    }
    func testReorderUnknownIdentityAndSelfDropAreRejected()throws {
        let q=TransferQueue(storageURL:nil,startPaused:true),a=q.enqueue(try spec(1))!,b=q.enqueue(try spec(2))!
        XCTAssertFalse(q.moveWaitingJob(UUID(),before:b));XCTAssertFalse(q.moveWaitingJob(a,before:UUID()));XCTAssertFalse(q.moveWaitingJob(a,before:a));XCTAssertEqual(q.jobs.map{$0.id},[a,b])
    }
    func testBatchPersistenceFailureDoesNotStartOrLeaveUnstoredJobs()throws {
        let blocker=root.appendingPathComponent("not-a-folder");try Data([1]).write(to:blocker)
        let q=TransferQueue(storageURL:blocker.appendingPathComponent("queue.json"),startPaused:true)
        XCTAssertTrue(q.enqueueSourceBatch(try spec(1)).isEmpty);XCTAssertTrue(q.jobs.isEmpty);XCTAssertFalse(q.isBusy);XCTAssertNotNil(q.errorMessage)
    }
    func testBatchSnapshotsAreUnaffectedByLaterDraftChanges()throws {
        let one=try spec(1),two=try spec(2),q=TransferQueue(storageURL:nil,startPaused:true)
        let settings=TransferJobSettings(sources:one.sources+two.sources,destinations:one.destinations,strategy:.standard,schedule:.perFile,buffer:.large,independentSourceVerification:true,ascMHLEnabled:true)
        q.enqueueSourceBatch(settings);q.draft.clearSources();q.draft.clearDestinations();q.draft.independentSourceVerification=false
        XCTAssertEqual(q.jobs.count,2)
        for job in q.jobs {XCTAssertEqual(job.settings.destinations,one.destinations);XCTAssertEqual(job.settings.buffer,.large);XCTAssertEqual(job.settings.schedule,.perFile);XCTAssertEqual(job.settings.strategy,.standard);XCTAssertEqual(job.settings.independentSourceVerification,true);XCTAssertEqual(job.settings.ascMHLEnabled,true)}
    }
    func testActualNSItemProviderRoundTripsQueueUUID()throws {
        let id=UUID(),type="local.nefcopy.waiting-job",provider=NSItemProvider(item:Data(id.uuidString.utf8) as NSData,typeIdentifier:type)
        var result:Data?,done=false
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(type))
        provider.loadDataRepresentation(forTypeIdentifier:type) {data,_ in result=data;done=true}
        wait{done};XCTAssertEqual(result.flatMap{String(data:$0,encoding:.utf8)}.flatMap{UUID(uuidString:$0)},id)
    }
}
final class QueuePresentationTests:XCTestCase {
    func testWaitingAlwaysStartsAtZeroEvenWithStaleProgress() {
        let p=QueueRowPresentation(state:.queued,workerState:.copying,progress:0.24,verified:true)
        XCTAssertEqual(p.title,"Waiting");XCTAssertEqual(p.percent,0);XCTAssertFalse(p.showsMetrics)
    }
    func testPausedRetainsActualProgressAndHidesSpeed() {
        let p=QueueRowPresentation(state:.running,workerState:.copying,progress:0.24,paused:true)
        XCTAssertEqual(p.title,"Paused");XCTAssertEqual(p.percent,24);XCTAssertFalse(p.showsMetrics)
    }
    func testCopyAndVerifyNeverReach100BeforeQueueCommit() {
        for phase in [JobState.copying,.verifying,.completed] {
            let p=QueueRowPresentation(state:.running,workerState:phase,progress:1,verified:true)
            XCTAssertEqual(p.percent,99)
        }
        XCTAssertEqual(QueueRowPresentation(state:.running,workerState:.verifying,progress:0.9).title,"Verifying")
    }
    func testOnlyVerifiedCompletionHas100PercentAndSuccess() {
        let passed=QueueRowPresentation(state:.verified,progress:1,verified:true)
        XCTAssertEqual(passed.percent,100);XCTAssertEqual(passed.title,"Completed")
        for state in [QueuedJobState.copied,.failed,.cancelled] {XCTAssertLessThan(QueueRowPresentation(state:state,progress:1,verified:false).percent,100)}
        XCTAssertLessThan(QueueRowPresentation(state:.verified,progress:1,verified:false).percent,100)
        XCTAssertLessThan(QueueRowPresentation(state:.verified,progress:1,verified:true,hasError:true).percent,100)
    }
    func testNonfiniteAndNegativeProgressCannotMakeFalseCompletion() {
        for value in [Double.nan,Double.infinity,-Double.infinity,-1] {
            let p=QueueRowPresentation(state:.running,workerState:.copying,progress:value)
            XCTAssertEqual(p.percent,0)
        }
    }
    func testOverallIncludesWaitingAndDoesNotHideFailedJob() {
        let done=QueueRowPresentation(state:.verified,verified:true),waiting=QueueRowPresentation(state:.queued)
        XCTAssertEqual(QueueRowPresentation.overall([done,waiting]),0.5)
        XCTAssertEqual(QueueRowPresentation.overall([]),0)
        XCTAssertLessThan(QueueRowPresentation.overall([done,QueueRowPresentation(state:.failed,progress:1)]),1)
    }
}
