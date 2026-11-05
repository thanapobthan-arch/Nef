import XCTest
import CryptoKit
@testable import NefCopy

final class PersistentQueueTests:XCTestCase {
    private var root:URL!
    private var store:URL {root.appendingPathComponent("state/queue.json")}
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopyPersistent-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func wait(_ condition:()->Bool) {
        let end=Date().addingTimeInterval(25)
        while !condition() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertTrue(condition(),"Timed out")
    }
    private func spec(_ name:String,verify:Bool=true)throws->TransferJobSettings {
        let source=root.appendingPathComponent(name+"-source")
        let dests=[root.appendingPathComponent(name+"-a"),root.appendingPathComponent(name+"-b")]
        for u in [source]+dests {try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true)}
        try Data(repeating:37,count:2*1024*1024).write(to:source.appendingPathComponent("data.bin"))
        try Data("ภาษาไทย".utf8).write(to:source.appendingPathComponent("ไทย.txt"))
        try Data().write(to:source.appendingPathComponent("empty"))
        return TransferJobSettings(sources:[source],destinations:dests,verify:verify,schedule:.perFile,buffer:.large,includeThumbnails:false)
    }
    private func sha(_ spec:TransferJobSettings)throws {
        for source in spec.sources {
            for file in try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) {
                for dest in spec.destinations {
                    XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:file)),SHA256.hash(data:try Data(contentsOf:dest.appendingPathComponent(source.lastPathComponent).appendingPathComponent(file.lastPathComponent))))
                }
            }
        }
    }
    private func edit(_ body:(inout [String:Any])->Void)throws {
        var value=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:store)) as? [String:Any])
        body(&value)
        try JSONSerialization.data(withJSONObject:value).write(to:store,options:.atomic)
    }
    func testPausedQueueRoundTripKeepsIDsOrderSettingsAndCopiesEachJob()throws {
        let a=try spec("round-a"),b=try spec("round-b")
        var first:TransferQueue?=TransferQueue(storageURL:store,startPaused:true)
        let aid=first!.enqueue(a)!,bid=first!.enqueue(b)!
        first!.moveWaitingJob(bid,earlier:true);first=nil
        let q=TransferQueue(storageURL:store)
        XCTAssertTrue(q.isQueuePaused);XCTAssertEqual(q.jobs.map{$0.id},[bid,aid])
        XCTAssertEqual(q.jobs[0].settings.schedule,.perFile);XCTAssertEqual(q.jobs[0].settings.buffer,.large)
        q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs.map{$0.state},[.verified,.verified]);try sha(a);try sha(b)
        XCTAssertGreaterThanOrEqual(q.jobs[1].startedAt!,q.jobs[0].finishedAt!)
    }
    func testInterruptedRunningBecomesQueuedAndRechecksPublishedFiles()throws {
        let s=try spec("interrupted")
        let seed=TransferQueue(storageURL:store,startPaused:true);let id=seed.enqueue(s)!
        // A final published file from the interrupted run is valid and must be preserved.
        let target=s.destinations[0].appendingPathComponent(s.sources[0].lastPathComponent)
        try FileManager.default.copyItem(at:s.sources[0],to:target)
        let before=try FileManager.default.attributesOfItem(atPath:target.appendingPathComponent("data.bin").path)[.systemFileNumber] as? NSNumber
        try edit { value in
            value["paused"]=false
            var jobs=value["jobs"] as! [[String:Any]];jobs[0]["state"]="Running";value["jobs"]=jobs
        }
        let q=TransferQueue(storageURL:store)
        XCTAssertEqual(q.jobs[0].id,id);XCTAssertEqual(q.jobs[0].state,.queued)
        wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.verified);XCTAssertTrue(q.jobs[0].engine!.revalidateExistingFiles)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:target.appendingPathComponent("data.bin").path)[.systemFileNumber] as? NSNumber,before)
        try sha(s)
    }
    func testCompletedJobsAndReportsRestoreWithoutRepeating()throws {
        let s=try spec("completed");let q=TransferQueue(storageURL:store)
        q.enqueue(s);wait{!q.isBusy && !q.hasPending}
        let restored=TransferQueue(storageURL:store)
        XCTAssertEqual(restored.jobs[0].state,.verified);XCTAssertFalse(restored.hasPending)
        XCTAssertEqual(restored.jobs[0].reportURLs,q.jobs[0].reportURLs)
        XCTAssertEqual(restored.jobs[0].finishedAt,q.jobs[0].finishedAt)
        XCTAssertNil(restored.jobs[0].engine);try sha(s)
    }
    func testCancelledAndRemovedJobsStayCancelledAndRemoved()throws {
        let a=try spec("cancelled"),b=try spec("removed")
        let q=TransferQueue(storageURL:store,startPaused:true)
        let aid=q.enqueue(a)!,bid=q.enqueue(b)!
        q.cancelJob(aid);q.removeJob(bid)
        let restored=TransferQueue(storageURL:store)
        XCTAssertEqual(restored.jobs.map{$0.id},[aid]);XCTAssertEqual(restored.jobs[0].state,.cancelled)
        restored.resumeQueue();XCTAssertFalse(restored.isBusy)
        XCTAssertFalse(FileManager.default.fileExists(atPath:a.destinations[0].appendingPathComponent(a.sources[0].lastPathComponent).path))
    }
    func testCancellationIntentSurvivesTerminationBeforeDrain()throws {
        let s=try spec("cancel-intent");let seed=TransferQueue(storageURL:store,startPaused:true);seed.enqueue(s)
        try edit { value in
            value["paused"]=false
            var jobs=value["jobs"] as! [[String:Any]];jobs[0]["state"]="Running";jobs[0]["cancellationRequested"]=true;value["jobs"]=jobs
        }
        let q=TransferQueue(storageURL:store)
        XCTAssertEqual(q.jobs[0].state,.cancelled);XCTAssertFalse(q.hasPending)
    }
    func testCorruptSnapshotIsPreservedAndNoJobStarts()throws {
        try FileManager.default.createDirectory(at:store.deletingLastPathComponent(),withIntermediateDirectories:true)
        let bad=Data("{incomplete".utf8);try bad.write(to:store)
        let q=TransferQueue(storageURL:store);XCTAssertNotNil(q.errorMessage);XCTAssertTrue(q.isQueuePaused)
        XCTAssertNil(q.enqueue(try spec("corrupt")));q.resumeQueue()
        XCTAssertFalse(q.isBusy);XCTAssertEqual(try Data(contentsOf:store),bad)
    }
    func testUnsupportedVersionIsPreserved()throws {
        let q=TransferQueue(storageURL:store,startPaused:true);q.enqueue(try spec("version"))
        try edit{$0["version"]=99};let original=try Data(contentsOf:store)
        let restored=TransferQueue(storageURL:store);XCTAssertNotNil(restored.errorMessage)
        XCTAssertTrue(restored.jobs.isEmpty);XCTAssertEqual(try Data(contentsOf:store),original)
    }
    func testSaveFailurePreventsStartingAndCanRecover()throws {
        let obstruction=root.appendingPathComponent("not-directory");try Data([1]).write(to:obstruction)
        let url=obstruction.appendingPathComponent("queue.json")
        let q=TransferQueue(storageURL:url);q.enqueue(try spec("save-failure"))
        XCTAssertTrue(q.isQueuePaused);XCTAssertFalse(q.isBusy);XCTAssertNotNil(q.errorMessage)
        try FileManager.default.removeItem(at:obstruction)
        q.resumeQueue();wait{!q.isBusy && !q.hasPending};XCTAssertEqual(q.jobs[0].state,.verified)
    }
    func testMissingDestinationDoesNotRecreateItAndNextJobRuns()throws {
        let missing=try spec("missing"),good=try spec("following")
        let q=TransferQueue(storageURL:store,startPaused:true);q.enqueue(missing);q.enqueue(good)
        try FileManager.default.removeItem(at:missing.destinations[0])
        let restored=TransferQueue(storageURL:store);restored.resumeQueue();wait{!restored.isBusy && !restored.hasPending}
        XCTAssertEqual(restored.jobs.map{$0.state},[.failed,.verified])
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.destinations[0].path));try sha(good)
    }
    func testDifferentVolumeIdentityBlocksRecovery()throws {
        let s=try spec("wrong-volume");let q=TransferQueue(storageURL:store,startPaused:true);q.enqueue(s)
        try edit { value in
            var jobs=value["jobs"] as! [[String:Any]]
            var volumes=jobs[0]["volumes"] as! [String:Any]
            var identity=volumes[s.destinations[0].standardizedFileURL.path] as! [String:Any]
            identity["uuid"]="another-drive";volumes[s.destinations[0].standardizedFileURL.path]=identity
            jobs[0]["volumes"]=volumes;value["jobs"]=jobs
        }
        let restored=TransferQueue(storageURL:store);restored.resumeQueue();wait{!restored.hasPending}
        XCTAssertEqual(restored.jobs[0].state,.failed);XCTAssertNil(restored.jobs[0].engine)
    }
    func testRecoveredCopyOnlyNeverBecomesVerified()throws {
        let s=try spec("copy-only",verify:false)
        let seed=TransferQueue(storageURL:store,startPaused:true);seed.enqueue(s)
        let q=TransferQueue(storageURL:store);q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.copied);XCTAssertFalse(q.canEjectDisplayedSources);try sha(s)
        XCTAssertEqual(TransferQueue(storageURL:store).jobs[0].state,.copied)
    }
    func testRecoveredMetadataCacheCannotHideTamperedDestination()throws {
        let s=try spec("tamper");let original=TransferQueue(storageURL:store);original.enqueue(s)
        wait{!original.isBusy && !original.hasPending}
        let target=s.destinations[0].appendingPathComponent(s.sources[0].lastPathComponent).appendingPathComponent("data.bin")
        let attrs=try FileManager.default.attributesOfItem(atPath:target.path)
        try Data(repeating:99,count:2*1024*1024).write(to:target)
        try FileManager.default.setAttributes([.modificationDate:attrs[.modificationDate]!],ofItemAtPath:target.path)
        try edit { value in
            value["paused"]=false;var jobs=value["jobs"] as! [[String:Any]]
            jobs[0]["state"]="Running";value["jobs"]=jobs
        }
        let q=TransferQueue(storageURL:store);wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.failed);XCTAssertFalse(q.canEjectDisplayedSources)
        XCTAssertEqual(try Data(contentsOf:target),Data(repeating:99,count:2*1024*1024))
    }
    func testRecoveryCleansOnlyOwnedStagingFiles()throws {
        let s=try spec("owned-partials"),q=TransferQueue(storageURL:store,startPaused:true)
        let id=q.enqueue(s)!
        let parent=s.destinations[0].appendingPathComponent(s.sources[0].lastPathComponent)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let owned=parent.appendingPathComponent(".nefcopy-partial-"+id.uuidString+"-leftover")
        let foreign=parent.appendingPathComponent(".nefcopy-partial-another-job")
        try Data([1,2]).write(to:owned);try Data([3,4]).write(to:foreign)
        let restored=TransferQueue(storageURL:store);restored.resumeQueue()
        wait{!restored.isBusy && !restored.hasPending}
        XCTAssertEqual(restored.jobs[0].state,.verified);try sha(s)
        XCTAssertFalse(FileManager.default.fileExists(atPath:owned.path))
        XCTAssertEqual(try Data(contentsOf:foreign),Data([3,4]))
    }
    func testRecoveryNeverDeletesStagingThroughEscapingSymlink()throws {
        let s=try spec("symlink"),q=TransferQueue(storageURL:store,startPaused:true)
        let id=q.enqueue(s)!
        let outside=root.appendingPathComponent("outside-selected-destination")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        let protected=outside.appendingPathComponent(".nefcopy-partial-"+id.uuidString+"-keep")
        try Data([7,8]).write(to:protected)
        try FileManager.default.createSymbolicLink(at:s.destinations[0].appendingPathComponent(s.sources[0].lastPathComponent),withDestinationURL:outside)
        let restored=TransferQueue(storageURL:store);restored.resumeQueue()
        wait{!restored.isBusy && !restored.hasPending}
        XCTAssertEqual(restored.jobs[0].state,.failed)
        XCTAssertEqual(try Data(contentsOf:protected),Data([7,8]))
    }
    func testActivePauseIsRestoredAsPausedWaitingJob()throws {
        let s=try spec("active-pause")
        try Data(repeating:23,count:16*1024*1024).write(to:s.sources[0].appendingPathComponent("data.bin"))
        let q=TransferQueue(storageURL:store,makeEngine:{_ in let engine=CopyEngine();engine.testCopyDelayPerChunk=0.1;return engine})
        q.enqueue(s)
        wait{q.displayedEngine?.currentFile.isEmpty == false}
        q.pauseActive();XCTAssertTrue(q.displayedEngine!.isPaused)
        let snapshot=try Data(contentsOf:store)
        q.cancelAll();wait{!q.isBusy}
        // Simulate the durable bytes present at process exit while paused.
        try snapshot.write(to:store,options:.atomic)
        let restored=TransferQueue(storageURL:store)
        XCTAssertTrue(restored.isQueuePaused);XCTAssertEqual(restored.jobs[0].state,.queued)
        XCTAssertFalse(restored.isBusy);restored.resumeQueue()
        wait{!restored.isBusy && !restored.hasPending}
        XCTAssertEqual(restored.jobs[0].state,.verified);try sha(s)
    }

}
