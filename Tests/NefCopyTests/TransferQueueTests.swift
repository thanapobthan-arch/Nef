import XCTest
import CryptoKit
@testable import NefCopy

final class TransferQueueTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopyQueue-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func wait(_ timeout:Double=20,_ condition:()->Bool) {
        let end=Date().addingTimeInterval(timeout)
        while !condition() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertTrue(condition(),"Timed out")
    }
    private func folder(_ name:String)throws->URL {
        let u=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true);return u
    }
    private func settings(_ name:String,megabytes:Int=1,twoDestinations:Bool=false,verify:Bool=true)throws->TransferJobSettings {
        let source=try folder(name+"-source")
        try Data(repeating:UInt8(name.utf8.first ?? 42),count:megabytes*1024*1024).write(to:source.appendingPathComponent("data.bin"))
        try Data("checksum ภาษาไทย ".utf8).write(to:source.appendingPathComponent("ภาษาไทย.txt"))
        try Data().write(to:source.appendingPathComponent("empty.bin"))
        var dests=[try folder(name+"-dest-a")]
        if twoDestinations {dests.append(try folder(name+"-dest-b"))}
        return TransferJobSettings(sources:[source],destinations:dests,verify:verify)
    }
    private func assertChecksums(_ spec:TransferJobSettings)throws {
        for source in spec.sources {
            for file in try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) {
                let expected=SHA256.hash(data:try Data(contentsOf:file))
                for d in spec.destinations {
                    let actual=d.appendingPathComponent(source.lastPathComponent).appendingPathComponent(file.lastPathComponent)
                    XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:actual)),expected)
                }
            }
        }
    }
    private func assertNoOverlap(_ q:TransferQueue) {
        for index in q.jobs.indices.dropFirst() {
            if let start=q.jobs[index].startedAt,let finish=q.jobs[index-1].finishedAt {XCTAssertGreaterThanOrEqual(start,finish)}
        }
    }
    func testThreeJobsRunFIFOAndEachDestinationHasCorrectSHA256AndLog()throws {
        let specs=try [settings("a",twoDestinations:true),settings("b",twoDestinations:true),settings("c",twoDestinations:true)]
        let q=TransferQueue(storageURL:nil,startPaused:true)
        let ids=specs.map{q.enqueue($0)!};q.resumeQueue();q.resumeQueue();q.resumeQueue()
        wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs.map{$0.id},ids);XCTAssertTrue(q.jobs.allSatisfy{$0.state == .verified})
        assertNoOverlap(q)
        for spec in specs {try assertChecksums(spec)}
        for job in q.jobs {
            XCTAssertEqual(job.reportURLs.count,2)
            for report in job.reportURLs {XCTAssertTrue(try String(contentsOf:report).contains("PASS"))}
        }
        XCTAssertTrue(q.canEjectDisplayedSources)
    }
    func testSnapshotDoesNotFollowLaterDraftEditsAndKeepsVerificationOptions()throws {
        let a=try settings("snapshot-a"),b=try settings("snapshot-b",verify:false)
        let q=TransferQueue(storageURL:nil,startPaused:true)
        q.draft.sourceURLs=a.sources;q.draft.destinations=a.destinations.map{Destination(url:$0)}
        q.draft.verifyEnabled=true;q.draft.ioBufferSize = .small;q.draft.verificationSchedule = .perFile
        let first=try XCTUnwrap(q.enqueueDraft())
        q.draft.sourceURLs=b.sources;q.draft.destinations=b.destinations.map{Destination(url:$0)};q.draft.verifyEnabled=false
        q.enqueueDraft();q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        let job=try XCTUnwrap(q.jobs.first{$0.id==first})
        XCTAssertEqual(job.settings.sources,a.sources);XCTAssertTrue(job.settings.verify)
        XCTAssertEqual(job.engine?.ioBufferSize,.small);XCTAssertEqual(job.engine?.verificationSchedule,.perFile)
        XCTAssertEqual(q.jobs.map{$0.state},[.verified,.copied]);XCTAssertFalse(q.canEjectDisplayedSources)
        try assertChecksums(a);try assertChecksums(b)
    }
    func testFailedJobDoesNotStopFollowingJobOrOverwriteConflict()throws {
        let bad=try settings("conflict"),good=try settings("good")
        let nested=bad.destinations[0].appendingPathComponent(bad.sources[0].lastPathComponent)
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        let conflict=nested.appendingPathComponent("data.bin");try Data("keep original".utf8).write(to:conflict)
        let q=TransferQueue(storageURL:nil,startPaused:true);q.enqueue(bad);q.enqueue(good);q.resumeQueue()
        wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs.map{$0.state},[.failed,.verified]);XCTAssertEqual(try String(contentsOf:conflict),"keep original")
        XCTAssertFalse(q.canEjectDisplayedSources);try assertChecksums(good);assertNoOverlap(q)
    }
    func testWaitingJobCanBeRemovedAndReorderedWithoutRunningIt()throws {
        let a=try settings("order-a"),b=try settings("order-b"),c=try settings("order-c")
        let q=TransferQueue(storageURL:nil,startPaused:true);let aid=q.enqueue(a)!,bid=q.enqueue(b)!,cid=q.enqueue(c)!
        q.moveWaitingJob(cid,earlier:true);q.removeJob(bid)
        XCTAssertEqual(q.jobs.map{$0.id},[aid,cid]);q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        try assertChecksums(a);try assertChecksums(c)
        XCTAssertFalse(FileManager.default.fileExists(atPath:b.destinations[0].appendingPathComponent(b.sources[0].lastPathComponent).path))
    }
    func testPauseQueueLetsCurrentJobFinishButHoldsNextJob()throws {
        let a=try settings("pause-a",megabytes:16),b=try settings("pause-b")
        let q=TransferQueue(storageURL:nil,makeEngine:{_ in let e=CopyEngine();e.testCopyDelayPerChunk=0.08;return e})
        q.enqueue(a);q.enqueue(b);q.pauseQueue()
        wait{!q.isBusy};XCTAssertEqual(q.jobs.map{$0.state},[.verified,.queued])
        XCTAssertNil(q.jobs[1].startedAt);q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        try assertChecksums(a);try assertChecksums(b);assertNoOverlap(q)
    }
    func testCancelActiveDrainsBeforeNextJobAndDoesNotVerifyCancelledJob()throws {
        let a=try settings("cancel-a",megabytes:32),b=try settings("cancel-b")
        let q=TransferQueue(storageURL:nil,makeEngine:{_ in let e=CopyEngine();e.testCopyDelayPerChunk=0.05;return e})
        let id=q.enqueue(a)!;q.enqueue(b)
        wait{(q.jobs[0].engine?.copiedBytes ?? 0)>0};q.cancelJob(id)
        wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs.map{$0.state},[.cancelled,.verified]);try assertChecksums(b);assertNoOverlap(q)
        let paths=(FileManager.default.enumerator(at:a.destinations[0],includingPropertiesForKeys:nil)?.allObjects as? [URL]) ?? []
        XCTAssertFalse(paths.contains{$0.lastPathComponent.hasPrefix(".nefcopy-partial-")})
        XCTAssertFalse(q.canEjectDisplayedSources)
    }
    func testCancelAllWhileActivePausedDoesNotStartWaitingJobs()throws {
        let a=try settings("all-a",megabytes:32),b=try settings("all-b")
        let q=TransferQueue(storageURL:nil,makeEngine:{_ in let e=CopyEngine();e.testCopyDelayPerChunk=0.05;return e})
        q.enqueue(a);q.enqueue(b);wait{(q.jobs[0].engine?.copiedBytes ?? 0)>0};q.pauseActive();q.cancelAll()
        wait{!q.isBusy};XCTAssertTrue(q.isQueuePaused)
        XCTAssertEqual(q.jobs.map{$0.state},[.cancelled,.cancelled]);XCTAssertNil(q.jobs[1].startedAt)
    }
    func testInvalidStartTerminatesInsteadOfHangingQueue()throws {
        let a=try settings("invalid"),good=try settings("after-invalid")
        let invalid=TransferJobSettings(sources:a.sources,destinations:a.sources)
        let q=TransferQueue(storageURL:nil,startPaused:true);q.enqueue(invalid);q.enqueue(good);q.resumeQueue()
        wait{!q.isBusy && !q.hasPending};XCTAssertEqual(q.jobs.map{$0.state},[.failed,.verified]);try assertChecksums(good)
    }
    func testRetryCreatesNewQueuedJobWithOriginalSnapshot()throws {
        let a=try settings("retry")
        let target=a.destinations[0].appendingPathComponent(a.sources[0].lastPathComponent)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let bad=target.appendingPathComponent("data.bin");try Data("conflict".utf8).write(to:bad)
        let q=TransferQueue(storageURL:nil);let id=q.enqueue(a)!;wait{!q.isBusy}
        XCTAssertEqual(q.jobs[0].state,.failed);try FileManager.default.removeItem(at:bad)
        let retry=try XCTUnwrap(q.retryJob(id));XCTAssertNotEqual(id,retry);wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs.map{$0.state},[.failed,.verified]);try assertChecksums(a);XCTAssertTrue(q.canEjectDisplayedSources)
    }
    func testAddingJobDuringTransferDoesNotChangeActivePaths()throws {
        let a=try settings("active",megabytes:16),b=try settings("added")
        let q=TransferQueue(storageURL:nil,makeEngine:{_ in let e=CopyEngine();e.testCopyDelayPerChunk=0.05;return e})
        q.enqueue(a);q.draft.sourceURLs=b.sources;q.draft.destinations=b.destinations.map{Destination(url:$0)}
        q.enqueueDraft();XCTAssertEqual(q.jobs[0].engine?.sourceURLs,a.sources)
        wait{!q.isBusy && !q.hasPending};try assertChecksums(a);try assertChecksums(b);assertNoOverlap(q)
    }
    func testCancelWaitingJobDoesNotStartIt()throws {
        let a=try settings("waiting")
        let q=TransferQueue(storageURL:nil,startPaused:true);let id=q.enqueue(a)!;q.cancelJob(id);q.resumeQueue()
        XCTAssertFalse(q.isBusy);XCTAssertEqual(q.jobs[0].state,.cancelled);XCTAssertNil(q.jobs[0].startedAt)
    }
    func testEmptyJobIsRejected()throws {
        let q=TransferQueue(storageURL:nil);XCTAssertNil(q.enqueue(TransferJobSettings(sources:[],destinations:[])))
        XCTAssertTrue(q.jobs.isEmpty);XCTAssertNotNil(q.errorMessage)
    }
}
