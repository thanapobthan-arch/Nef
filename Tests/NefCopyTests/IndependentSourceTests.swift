import XCTest
import CryptoKit
@testable import NefCopy

final class IndependentSourceTests:XCTestCase {
    private var root:URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopyIndependent-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    private func wait(_ condition:()->Bool) {
        let end=Date().addingTimeInterval(25)
        while !condition() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertTrue(condition(),"Timed out")
    }
    private func setup(_ strategy:TransferStrategy = .singleReadFanOut)throws->(CopyEngine,URL,[URL]) {
        let source=root.appendingPathComponent("การ์ด"),dests=[root.appendingPathComponent("a"),root.appendingPathComponent("b")]
        for u in [source]+dests {try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true)}
        try Data(repeating:0xA7,count:12*1024*1024).write(to:source.appendingPathComponent("data.bin"))
        try Data("ภาษาไทย-日本語-🎬".utf8).write(to:source.appendingPathComponent("ไทย.txt"))
        try Data().write(to:source.appendingPathComponent("empty"))
        let e=CopyEngine();e.sourceURLs=[source];e.destinations=dests.map{Destination(url:$0)}
        e.independentSourceVerification=true;e.transferStrategy=strategy;e.cascadePrimaryDestination=dests[0]
        return(e,source,dests)
    }
    private func bytes(_ source:URL)throws->Int64 {
        try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil).reduce(Int64(0)){$0+Int64(try Data(contentsOf:$1).count)}
    }
    private func check(_ source:URL,_ dests:[URL])throws {
        for file in try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) {
            for dest in dests {
                XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:file)),SHA256.hash(data:try Data(contentsOf:dest.appendingPathComponent(source.lastPathComponent).appendingPathComponent(file.lastPathComponent))))
            }
        }
    }
    private func successful(_ strategy:TransferStrategy,_ schedule:VerificationSchedule)throws {
        let(e,s,d)=try setup(strategy);e.verificationSchedule=schedule;e.start();wait{!e.isRunning}
        XCTAssertTrue(e.lastRunWasVerified,e.errorMessage ?? "");XCTAssertEqual(e.passCount,6);XCTAssertEqual(e.failCount,0)
        XCTAssertEqual(e.independentSourceReadBytes,try bytes(s));XCTAssertEqual(e.independentSourceVerifiedFiles,3)
        try check(s,d)
        for progress in e.destinationProgress {
            let report=try XCTUnwrap(progress.report);let text=try String(contentsOf:report)
            XCTAssertTrue(text.contains("Independent source mode requested: true"))
            XCTAssertTrue(text.contains("Independently pre-read files: 3"))
        }
    }
    func testMultiDriveAfterCopy()throws {try successful(.singleReadFanOut,.afterCopy)}
    func testMultiDrivePerFile()throws {try successful(.singleReadFanOut,.perFile)}
    func testMultiDrivePipelined()throws {try successful(.singleReadFanOut,.pipelined)}
    func testStandardAfterCopy()throws {try successful(.standard,.afterCopy)}
    func testStandardPerFile()throws {try successful(.standard,.perFile)}
    func testStandardPipelined()throws {try successful(.standard,.pipelined)}
    func testCascadingAfterCopy()throws {try successful(.cascading,.afterCopy)}
    func testCascadingPipelined()throws {try successful(.cascading,.pipelined)}
    func testOffKeepsOriginalReadPath()throws {
        let(e,s,d)=try setup();e.independentSourceVerification=false;e.start();wait{!e.isRunning}
        XCTAssertTrue(e.lastRunWasVerified);XCTAssertEqual(e.independentSourceReadBytes,0);XCTAssertEqual(e.independentSourceVerifiedFiles,0);try check(s,d)
    }
    private func tamperAfterPreRead(_ strategy:TransferStrategy)throws {
        let(e,s,d)=try setup(strategy);let file=s.appendingPathComponent("data.bin")
        let date=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:file.path)[.modificationDate] as? Date)
        e.testAfterIndependentSourceVerification={
            try Data(repeating:0xB8,count:12*1024*1024).write(to:file)
            try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:file.path)
        }
        e.start();wait{!e.isRunning};XCTAssertFalse(e.lastRunWasVerified);XCTAssertEqual(e.state,.failed)
        for dest in d {XCTAssertFalse(FileManager.default.fileExists(atPath:dest.appendingPathComponent("การ์ด/data.bin").path))}
    }
    func testSameSizeAndTimeTamperingBlockedMultiDrive()throws {try tamperAfterPreRead(.singleReadFanOut)}
    func testSameSizeAndTimeTamperingBlockedStandard()throws {try tamperAfterPreRead(.standard)}
    func testSameSizeAndTimeTamperingBlockedCascade()throws {try tamperAfterPreRead(.cascading)}
    func testExistingDestinationCannotUseMetadataOnlyManifest()throws {
        let(e,s,d)=try setup();e.independentSourceVerification=false;e.start();wait{!e.isRunning};XCTAssertTrue(e.lastRunWasVerified)
        let target=d[0].appendingPathComponent("การ์ด/data.bin")
        let date=try XCTUnwrap(try FileManager.default.attributesOfItem(atPath:target.path)[.modificationDate] as? Date)
        try Data(repeating:0xFF,count:12*1024*1024).write(to:target)
        try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:target.path)
        e.independentSourceVerification=true;e.start();wait{!e.isRunning}
        XCTAssertFalse(e.lastRunWasVerified);XCTAssertEqual(e.state,.failed);XCTAssertEqual(e.independentSourceReadBytes,try bytes(s))
    }
    func testCancelBeforeAnyCopyStarts()throws {
        let(e,_,d)=try setup();e.testHashDelayPerChunk=0.2;e.start()
        wait{e.independentSourceReadBytes>0};e.cancel();wait{!e.isRunning}
        XCTAssertEqual(e.state,.cancelled);XCTAssertFalse(e.lastRunWasVerified)
        for dest in d {XCTAssertFalse(FileManager.default.fileExists(atPath:dest.appendingPathComponent("การ์ด").path))}
    }
    func testSourceDisappearingDuringPreReadBlocksCopy()throws {
        let(e,s,d)=try setup();e.testHashDelayPerChunk=0.2;e.start()
        wait{e.independentSourceReadBytes>0}
        try FileManager.default.removeItem(at:s)
        wait{!e.isRunning};XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.lastRunWasVerified)
        for dest in d {XCTAssertFalse(FileManager.default.fileExists(atPath:dest.appendingPathComponent("การ์ด").path))}
    }
    func testSourceGrowingDuringPreReadBlocksCopy()throws {
        let(e,s,d)=try setup();e.testHashDelayPerChunk=0.2;e.start()
        wait{e.independentSourceReadBytes>0}
        let handle=try FileHandle(forWritingTo:s.appendingPathComponent("data.bin"))
        try handle.seekToEnd();try handle.write(contentsOf:Data([1]));try handle.close()
        wait{!e.isRunning};XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.lastRunWasVerified)
        for dest in d {XCTAssertFalse(FileManager.default.fileExists(atPath:dest.appendingPathComponent("การ์ด").path))}
    }
    func testPauseAndResumeDuringIndependentPass()throws {
        let(e,s,d)=try setup();e.testHashDelayPerChunk=0.1;e.start();wait{e.independentSourceReadBytes>0}
        e.pauseTransfer();XCTAssertTrue(e.isPaused)
        RunLoop.main.run(until:Date().addingTimeInterval(0.15));let count=e.independentSourceReadBytes
        RunLoop.main.run(until:Date().addingTimeInterval(0.2));XCTAssertEqual(e.independentSourceReadBytes,count)
        e.resumeTransfer();wait{!e.isRunning};XCTAssertTrue(e.lastRunWasVerified);try check(s,d)
    }
    func testQueuePersistsModeAndReopensWithIndependentPass()throws {
        let(e,s,d)=try setup();let store=root.appendingPathComponent("queue.json")
        var q:TransferQueue?=TransferQueue(storageURL:store,startPaused:true)
        XCTAssertNotNil(q!.enqueue(TransferJobSettings(engine:e)));q=nil
        let restored=TransferQueue(storageURL:store)
        XCTAssertEqual(restored.jobs.first?.settings.independentSourceVerification,true)
        restored.resumeQueue();wait{!restored.isBusy && !restored.hasPending}
        XCTAssertEqual(restored.jobs.first?.state,.verified)
        XCTAssertEqual(restored.jobs.first?.engine?.independentSourceReadBytes,try bytes(s));try check(s,d)
    }
    func testLegacyQueueSettingDefaultsToOff()throws {
        let(e,_,_)=try setup();let data=try JSONEncoder().encode(TransferJobSettings(engine:e))
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);object.removeValue(forKey:"independentSourceVerification")
        let decoded=try JSONDecoder().decode(TransferJobSettings.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertFalse(decoded.independentSourceVerification ?? false)
    }
    func testCannotEnableIndependentModeWithDestinationVerificationOff()throws {
        let(e,_,_)=try setup();e.verifyEnabled=false
        var result:PreflightResult?;e.runPreflight{result=$0};wait{result != nil}
        XCTAssertFalse(try XCTUnwrap(result).ok)
    }
}
