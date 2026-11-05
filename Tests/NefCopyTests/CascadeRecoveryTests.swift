import XCTest
import CryptoKit
@testable import NefCopy

final class CascadeRecoveryTests:XCTestCase {
    private var root:URL!
    private var store:URL {root.appendingPathComponent("state/queue.json")}
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopySSDRecovery-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func wait(_ condition:()->Bool) {
        let deadline=Date().addingTimeInterval(25)
        while !condition() && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertTrue(condition(),"Timed out")
    }
    private func setup(independent:Bool=false)throws->TransferJobSettings {
        let source=root.appendingPathComponent("card"),primary=root.appendingPathComponent("ssd"),backup=root.appendingPathComponent("backup")
        for u in [source,primary,backup] {try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true)}
        try Data(repeating:73,count:16*1024*1024).write(to:source.appendingPathComponent("data.bin"))
        try Data("กู้คิวจาก SSD".utf8).write(to:source.appendingPathComponent("ไทย.txt"))
        try Data().write(to:source.appendingPathComponent("empty"))
        return TransferJobSettings(sources:[source],destinations:[primary,backup],strategy:.cascading,cascadePrimaryDestination:primary,independentSourceVerification:independent)
    }
    private func edit(_ body:(inout [String:Any])->Void)throws {
        var object=try JSONSerialization.jsonObject(with:Data(contentsOf:store)) as! [String:Any]
        body(&object);try JSONSerialization.data(withJSONObject:object).write(to:store,options:.atomic)
    }
    private func seed(independent:Bool=false)throws->(TransferJobSettings,[String:Data],UUID) {
        let settings=try setup(independent:independent)
        var expected:[String:Data]=[:]
        for name in ["data.bin","ไทย.txt","empty"] {expected[name]=Data(SHA256.hash(data:try Data(contentsOf:settings.sources[0].appendingPathComponent(name))))}
        let q=TransferQueue(storageURL:store,makeEngine:{spec in
            let engine=CopyEngine();engine.testDestinationWriteDelays[spec.destinations[1].path]=0.1;return engine
        })
        let id=q.enqueue(settings)!
        wait{q.displayedEngine?.cascadeSourceReleased==true}
        q.pauseActive()
        let saved=try Data(contentsOf:store)
        let snapshot=try JSONSerialization.jsonObject(with:saved) as! [String:Any]
        XCTAssertNotNil((snapshot["jobs"] as! [[String:Any]])[0]["cascadeCheckpoint"])
        q.cancelAll();wait{!q.isBusy}
        try saved.write(to:store,options:.atomic)
        try FileManager.default.moveItem(at:settings.sources[0],to:root.appendingPathComponent("original-offline"))
        return(settings,expected,id)
    }
    private func check(_ hashes:[String:Data],settings:TransferJobSettings)throws {
        for destination in settings.destinations {
            for (name,hash) in hashes {XCTAssertEqual(Data(SHA256.hash(data:try Data(contentsOf:destination.appendingPathComponent("card/"+name)))),hash)}
        }
    }
    func testReopenWithoutOriginalRehashesSSDAndFinishesWithSameJobID()throws {
        let(s,hashes,id)=try seed()
        let primary=s.destinations[0].appendingPathComponent("card/data.bin")
        let inode=try FileManager.default.attributesOfItem(atPath:primary.path)[.systemFileNumber] as? NSNumber
        let q=TransferQueue(storageURL:store);XCTAssertTrue(q.isQueuePaused);XCTAssertEqual(q.jobs[0].id,id)
        q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.verified);XCTAssertEqual(q.jobs[0].engine?.originalSourceReadBytes,0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:primary.path)[.systemFileNumber] as? NSNumber,inode)
        XCTAssertFalse(FileManager.default.fileExists(atPath:s.sources[0].path));try check(hashes,settings:s)
    }
    func testIndependentModeRecoversFromSSDWithoutOriginalSource()throws {
        let(s,hashes,id)=try seed(independent:true)
        let q=TransferQueue(storageURL:store)
        XCTAssertEqual(q.jobs[0].settings.independentSourceVerification,true)
        q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.verified);XCTAssertEqual(q.jobs[0].id,id)
        XCTAssertEqual(q.jobs[0].engine?.independentSourceReadBytes,0)
        XCTAssertEqual(q.jobs[0].engine?.originalSourceReadBytes,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:s.sources[0].path));try check(hashes,settings:s)
    }
    func testTamperedSSDWithOriginalSizeAndMtimeBlocksForwarding()throws {
        let(s,_,_)=try seed();let file=s.destinations[0].appendingPathComponent("card/data.bin")
        let attrs=try FileManager.default.attributesOfItem(atPath:file.path)
        try Data(repeating:29,count:16*1024*1024).write(to:file)
        try FileManager.default.setAttributes([.modificationDate:attrs[.modificationDate]!],ofItemAtPath:file.path)
        let q=TransferQueue(storageURL:store);q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.failed);XCTAssertFalse(q.jobs[0].engine!.cascadeSourceReleased)
        XCTAssertTrue(q.jobs[0].error?.contains("checksum") == true)
        XCTAssertEqual(try Data(contentsOf:file),Data(repeating:29,count:16*1024*1024))
    }
    func testMissingPrimaryIsNotRecreatedAndNextJobCanRun()throws {
        let(s,_,_)=try seed();try FileManager.default.moveItem(at:s.destinations[0],to:root.appendingPathComponent("ssd-offline"))
        let q=TransferQueue(storageURL:store)
        let source=root.appendingPathComponent("following.bin"),dest=root.appendingPathComponent("following-dest")
        try Data([1,9,3]).write(to:source);try FileManager.default.createDirectory(at:dest,withIntermediateDirectories:true)
        q.enqueue(TransferJobSettings(sources:[source],destinations:[dest]));q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs.map{$0.state},[.failed,.verified]);XCTAssertFalse(FileManager.default.fileExists(atPath:s.destinations[0].path))
        XCTAssertEqual(try Data(contentsOf:dest.appendingPathComponent(source.lastPathComponent)),Data([1,9,3]))
    }
    func testChangedPrimaryVolumeIdentityIsRejected()throws {
        _=try seed()
        try edit { value in
            var jobs=value["jobs"] as! [[String:Any]],checkpoint=jobs[0]["cascadeCheckpoint"] as! [String:Any]
            var volume=checkpoint["primaryVolume"] as! [String:Any];volume["uuid"]="different-device"
            checkpoint["primaryVolume"]=volume;jobs[0]["cascadeCheckpoint"]=checkpoint;value["jobs"]=jobs
        }
        let q=TransferQueue(storageURL:store);q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.failed);XCTAssertTrue(q.jobs[0].error?.contains("SSD") == true)
    }
    func testInvalidCheckpointPathAndVersionCannotEscapePrimary()throws {
        _=try seed();let saved=try Data(contentsOf:store)
        for badPath in ["../outside.bin","/absolute.bin","card/../../outside.bin"] {
            try saved.write(to:store,options:.atomic)
            try edit { value in
                var jobs=value["jobs"] as! [[String:Any]],checkpoint=jobs[0]["cascadeCheckpoint"] as! [String:Any]
                var files=checkpoint["files"] as! [[String:Any]];files[0]["relativePath"]=badPath
                checkpoint["files"]=files;jobs[0]["cascadeCheckpoint"]=checkpoint;value["jobs"]=jobs
            }
            let q=TransferQueue(storageURL:store);q.resumeQueue();wait{!q.hasPending}
            XCTAssertEqual(q.jobs[0].state,.failed);XCTAssertNil(q.jobs[0].engine)
        }
        try saved.write(to:store,options:.atomic)
        try edit { value in
            var jobs=value["jobs"] as! [[String:Any]],checkpoint=jobs[0]["cascadeCheckpoint"] as! [String:Any]
            checkpoint["version"]=99;jobs[0]["cascadeCheckpoint"]=checkpoint;value["jobs"]=jobs
        }
        let q=TransferQueue(storageURL:store);q.resumeQueue();wait{!q.hasPending};XCTAssertEqual(q.jobs[0].state,.failed)
    }
    func testMissingCheckpointStillRequiresOriginalAndDoesNotGuessFromSSD()throws {
        _=try seed()
        try edit { value in var jobs=value["jobs"] as! [[String:Any]];jobs[0].removeValue(forKey:"cascadeCheckpoint");value["jobs"]=jobs }
        let q=TransferQueue(storageURL:store);q.resumeQueue();wait{!q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.failed);XCTAssertNil(q.jobs[0].engine)
    }
    func testOnlyPlannedSSDFilesAreUsedOnRecovery()throws {
        let(s,hashes,_)=try seed()
        let extra=s.destinations[0].appendingPathComponent("unrelated-test.bin");try Data([9,9,9]).write(to:extra)
        let q=TransferQueue(storageURL:store);q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.verified);try check(hashes,settings:s)
        XCTAssertFalse(FileManager.default.fileExists(atPath:s.destinations[1].appendingPathComponent(extra.lastPathComponent).path))
        XCTAssertEqual(try Data(contentsOf:extra),Data([9,9,9]))
    }
    func testCheckpointSaveFailureDoesNotReleaseOriginalOrStartSecondaries()throws {
        let s=try setup(),parent=store.deletingLastPathComponent(),backup=root.appendingPathComponent("old-state")
        let q=TransferQueue(storageURL:store,makeEngine:{_ in
            let e=CopyEngine();e.testCascadeBeforeForward={_ in
                try! FileManager.default.moveItem(at:parent,to:backup)
                try! Data([1]).write(to:parent)
            };return e
        })
        q.enqueue(s);wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.failed);XCTAssertTrue(q.isQueuePaused)
        XCTAssertFalse(q.jobs[0].engine!.cascadeSourceReleased)
        XCTAssertFalse(FileManager.default.fileExists(atPath:s.destinations[1].appendingPathComponent("card").path))
        let old=try JSONSerialization.jsonObject(with:Data(contentsOf:backup.appendingPathComponent("queue.json"))) as! [String:Any]
        XCTAssertNil((old["jobs"] as! [[String:Any]])[0]["cascadeCheckpoint"])
    }
    func testCancelStaysCancelledButExplicitRetryUsesSavedSSD()throws {
        let(s,hashes,id)=try seed()
        let q=TransferQueue(storageURL:store);q.cancelJob(id)
        let reopened=TransferQueue(storageURL:store);XCTAssertEqual(reopened.jobs[0].state,.cancelled)
        reopened.resumeQueue();XCTAssertFalse(reopened.isBusy)
        reopened.retryJob(id);wait{!reopened.isBusy && !reopened.hasPending}
        XCTAssertEqual(reopened.jobs.map{$0.state},[.cancelled,.verified]);try check(hashes,settings:s)
    }
    func testRepeatedReopeningKeepsSourceFreeCheckpoint()throws {
        let(s,hashes,_)=try seed()
        let q=TransferQueue(storageURL:store,makeEngine:{spec in let e=CopyEngine();e.testDestinationWriteDelays[spec.destinations[1].path]=0.1;return e})
        q.resumeQueue();wait{q.displayedEngine?.cascadeSourceReleased==true};q.pauseActive()
        let saved=try Data(contentsOf:store);q.cancelAll();wait{!q.isBusy}
        try saved.write(to:store,options:.atomic)
        let again=TransferQueue(storageURL:store);again.resumeQueue();wait{!again.isBusy && !again.hasPending}
        XCTAssertEqual(again.jobs[0].state,.verified);XCTAssertEqual(again.jobs[0].engine?.originalSourceReadBytes,0)
        try check(hashes,settings:s)
    }
    func testRecoveryCleansOwnedLegacyReplacementFilesAndPreservesOthers()throws {
        let(settings,hashes,id)=try seed()
        let parent=settings.destinations[1].appendingPathComponent("card")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let mixed=parent.appendingPathComponent("(A Document Being Saved By NefCopy)"),empty=parent.appendingPathComponent("(A Document Being Saved By NefCopy 2)")
        for directory in [mixed,empty] {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
        let prefix=".nefcopy-partial-"+id.uuidString+"-"
        let owned=mixed.appendingPathComponent(prefix+"old"),other=mixed.appendingPathComponent(".nefcopy-partial-other-job")
        try Data([1]).write(to:owned);try Data([2]).write(to:other)
        try Data([3]).write(to:empty.appendingPathComponent(prefix+"old"))
        let q=TransferQueue(storageURL:store);q.resumeQueue();wait{!q.isBusy && !q.hasPending}
        XCTAssertEqual(q.jobs[0].state,.verified);try check(hashes,settings:settings)
        XCTAssertFalse(FileManager.default.fileExists(atPath:owned.path))
        XCTAssertEqual(try Data(contentsOf:other),Data([2]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:empty.path))
    }

}
