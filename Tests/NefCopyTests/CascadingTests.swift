import XCTest
import CryptoKit
@testable import NefCopy

final class CascadingTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopyCascade-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func wait(_ condition:()->Bool) {
        let deadline=Date().addingTimeInterval(25)
        while !condition() && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertTrue(condition(),"Timed out")
    }
    private func setup(_ extra:Bool=false)throws->(CopyEngine,URL,[URL]) {
        let source=root.appendingPathComponent("card")
        let dests=["ssd","backup-a"]+(extra ? ["backup-b"]:[])
        let urls=dests.map{root.appendingPathComponent($0)}
        for u in [source]+urls {try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true)}
        try Data(repeating:90,count:16*1024*1024).write(to:source.appendingPathComponent("data.bin"))
        try Data("ภาษาไทย checksum".utf8).write(to:source.appendingPathComponent("ไทย.txt"))
        try Data().write(to:source.appendingPathComponent("empty"))
        let nested=source.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        try Data([1,2,3,4]).write(to:nested.appendingPathComponent("clip.bin"))
        let e=CopyEngine();e.sourceURLs=[source];e.destinations=urls.map{Destination(url:$0)}
        e.transferStrategy = .cascading;e.cascadePrimaryDestination=urls[0]
        return(e,source,urls)
    }
    private func files(_ source:URL)->[URL] {
        ((FileManager.default.enumerator(at:source,includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL]) ?? []).filter{(try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true}
    }
    private func expected(_ source:URL)throws->[String:Data] {
        var result:[String:Data]=[:]
        for file in files(source) {result[file.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(source.standardizedFileURL.resolvingSymlinksInPath().pathComponents.count).joined(separator:"/")]=Data(SHA256.hash(data:try Data(contentsOf:file)))}
        return result
    }
    private func check(_ hashes:[String:Data],at destination:URL)throws {
        for (relative,digest) in hashes {XCTAssertEqual(Data(SHA256.hash(data:try Data(contentsOf:destination.appendingPathComponent("card/"+relative)))),digest)}
    }
    func testPrimaryVerifiedBeforeSecondaryStartsAndAllSHA256Match()throws {
        let(e,s,d)=try setup();let hashes=try expected(s)
        e.testDestinationWriteDelays[d[0].path]=0.03;e.testDestinationWriteDelays[d[1].path]=0.03
        e.start();wait{e.copiedBytes>0}
        XCTAssertFalse(e.cascadeSourceReleased)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d[1].appendingPathComponent("card").path))
        wait{e.cascadeSourceReleased};XCTAssertTrue(e.isRunning)
        XCTAssertTrue(e.destinationProgress.contains{$0.path==d[0].path && $0.verified})
        wait{!e.isRunning};XCTAssertTrue(e.lastRunWasVerified);XCTAssertEqual(e.state,.completed)
        for dest in d {try check(hashes,at:dest)}
        XCTAssertEqual(e.originalSourceReadBytes,Int64(16*1024*1024+Data("ภาษาไทย checksum".utf8).count+4))
        XCTAssertEqual(e.passCount,8);XCTAssertEqual(e.destinationProgress.compactMap{$0.report}.count,2)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d[1].appendingPathComponent("NefCopy Reports/NefCopy Reports").path))
    }
    func testOriginalSourceCanDisappearAfterVerifiedHandoff()throws {
        let(e,s,d)=try setup();let hashes=try expected(s)
        e.testDestinationWriteDelays[d[1].path]=0.05;e.start();wait{e.cascadeSourceReleased}
        try FileManager.default.moveItem(at:s,to:root.appendingPathComponent("removed-original"))
        wait{!e.isRunning};XCTAssertTrue(e.lastRunWasVerified)
        for dest in d {try check(hashes,at:dest)}
    }
    func testPrimaryWriteFailureBlocksEverySecondary()throws {
        let(e,_,d)=try setup(true);e.testDestinationFailureBytes[d[0].path]=0
        e.start();wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.cascadeSourceReleased);XCTAssertFalse(e.lastRunWasVerified)
        for dest in d.dropFirst() {XCTAssertFalse(FileManager.default.fileExists(atPath:dest.appendingPathComponent("card").path))}
    }
    func testPrimaryChecksumFailureBlocksEverySecondary()throws {
        let(e,_,d)=try setup();e.testCascadeCorruptPrimary=true;e.start();wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.cascadeSourceReleased)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d[1].appendingPathComponent("card").path))
    }
    func testTamperedPrimaryCannotProduceFalseVerifiedSecondaries()throws {
        let(e,_,d)=try setup()
        e.testCascadeBeforeForward={primary in
            let target=primary.appendingPathComponent("card/data.bin")
            let attrs=try! FileManager.default.attributesOfItem(atPath:target.path)
            try! Data(repeating:31,count:16*1024*1024).write(to:target)
            try! FileManager.default.setAttributes([.modificationDate:attrs[.modificationDate]!],ofItemAtPath:target.path)
        }
        e.start();wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.lastRunWasVerified)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d[1].appendingPathComponent("card/data.bin").path))
    }
    func testSecondaryFailureDoesNotCancelAnotherSecondary()throws {
        let(e,s,d)=try setup(true);let hashes=try expected(s)
        e.testDestinationFailureBytes[d[1].path]=0;e.testDestinationWriteDelays[d[2].path]=0.03
        e.start();wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.lastRunWasVerified)
        try check(hashes,at:d[0]);try check(hashes,at:d[2])
        XCTAssertTrue(e.destinationProgress.contains{$0.path==d[2].path && $0.verified})
    }
    func testPrimaryDisconnectDuringForwardingFailsOverallAndDrainsWorkers()throws {
        let(e,_,d)=try setup();e.testDestinationWriteDelays[d[1].path]=0.1
        e.start();wait{e.cascadeSourceReleased};e.testDisconnectDestination(d[0]);wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.lastRunWasVerified);XCTAssertFalse(e.canSafeEject)
    }
    func testPauseResumeDuringForwardingAndCancellationDrain()throws {
        let(e,_,d)=try setup();e.testDestinationWriteDelays[d[1].path]=0.1
        e.start();wait{e.cascadeSourceReleased};e.pauseTransfer();XCTAssertTrue(e.isPaused)
        RunLoop.main.run(until:Date().addingTimeInterval(0.2));let bytes=e.copiedBytes
        RunLoop.main.run(until:Date().addingTimeInterval(0.1));XCTAssertEqual(e.copiedBytes,bytes)
        e.resumeTransfer();XCTAssertFalse(e.isPaused);e.cancel();wait{!e.isRunning}
        XCTAssertEqual(e.state,.cancelled);XCTAssertFalse(e.lastRunWasVerified)
        XCTAssertTrue(files(d[1]).allSatisfy{!$0.lastPathComponent.hasPrefix(".nefcopy-partial-")})
    }
    func testCancelDuringPrimaryDoesNotStartSecondaries()throws {
        let(e,_,d)=try setup();e.testDestinationWriteDelays[d[0].path]=0.1
        e.start();wait{e.copiedBytes>0};e.cancel();wait{!e.isRunning}
        XCTAssertEqual(e.state,.cancelled);XCTAssertFalse(e.cascadeSourceReleased)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d[1].appendingPathComponent("card").path))
    }
    func testRequiresVerificationAndExplicitPrimary()throws {
        let(e,_,_)=try setup();e.verifyEnabled=false;e.start()
        XCTAssertFalse(e.isRunning);XCTAssertNotNil(e.errorMessage)
        e.verifyEnabled=true;e.cascadePrimaryDestination=nil;e.start()
        XCTAssertFalse(e.isRunning);XCTAssertTrue(e.errorMessage?.contains("primary SSD")==true)
    }
    func testOverlappingDestinationsAreRejected()throws {
        let(e,_,d)=try setup();e.destinations=[Destination(url:d[0]),Destination(url:d[0].appendingPathComponent("nested"))]
        e.start();XCTAssertFalse(e.isRunning);XCTAssertTrue(e.errorMessage?.contains("overlap")==true)
    }
    func testPrimaryCanBeAnySelectedDestinationAndSingleFileNamesStayStable()throws {
        let(e,s,d)=try setup();let single=root.appendingPathComponent("separate.bin");try Data([6,7,8]).write(to:single)
        e.sourceURLs=[s,single];e.cascadePrimaryDestination=d[1];e.start();wait{!e.isRunning}
        XCTAssertTrue(e.lastRunWasVerified)
        for dest in d {XCTAssertEqual(try Data(contentsOf:dest.appendingPathComponent("separate.bin")),Data([6,7,8]));try check(expected(s),at:dest)}
    }
    func testQueuePersistsPrimarySelectionAndRunsAfterReopening()throws {
        let(e,s,d)=try setup();let store=root.appendingPathComponent("queue.json"),hashes=try expected(s)
        var q:TransferQueue?=TransferQueue(storageURL:store,startPaused:true)
        q!.enqueue(TransferJobSettings(engine:e));q=nil
        let restored=TransferQueue(storageURL:store)
        XCTAssertEqual(restored.jobs[0].settings.strategy,.cascading)
        XCTAssertEqual(restored.jobs[0].settings.cascadePrimaryDestination,d[0])
        restored.resumeQueue();wait{!restored.isBusy && !restored.hasPending}
        XCTAssertEqual(restored.jobs[0].state,.verified)
        for dest in d {try check(hashes,at:dest)}
    }
    func testOldSettingsWithoutPrimaryDecodeAndNormalModeStillWorks()throws {
        let(e,_,_)=try setup();e.transferStrategy = .singleReadFanOut
        var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(TransferJobSettings(engine:e))) as! [String:Any]
        value.removeValue(forKey:"cascadePrimaryDestination")
        let settings=try JSONDecoder().decode(TransferJobSettings.self,from:JSONSerialization.data(withJSONObject:value))
        XCTAssertNil(settings.cascadePrimaryDestination);XCTAssertEqual(settings.strategy,.singleReadFanOut)
    }
}
