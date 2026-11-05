import XCTest
@testable import NefCopy

final class ParallelVerificationTests:XCTestCase {
    private var root:URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopyParallel-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    private func file(_ name:String,megabytes:Int=1)throws->URL {
        let u=root.appendingPathComponent(name)
        try Data(repeating:0xa5,count:megabytes*1024*1024).write(to:u);return u
    }
    private func wait(_ timeout:Double=12,_ condition:()->Bool) {
        let deadline=Date().addingTimeInterval(timeout)
        while !condition() && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(),"Timed out")
    }
    private func engine(_ source:URL)throws->(CopyEngine,URL,URL) {
        let a=root.appendingPathComponent("dest-a"),b=root.appendingPathComponent("dest-b")
        for d in [a,b] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)}
        let e=CopyEngine();e.sourceURLs=[source];e.addDestinationURL(a);e.addDestinationURL(b)
        e.testVerificationDeviceKeys=[a.standardizedFileURL.path:"device-a",b.standardizedFileURL.path:"device-b"]
        return(e,a,b)
    }
    func testDeviceGroupingKeepsSameVolumeInOneLane()throws {
        let a=root.appendingPathComponent("group-a"),b=root.appendingPathComponent("group-b")
        for d in [a,b] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)}
        let first=BoundedVerifier.deviceKey(for:a),second=BoundedVerifier.deviceKey(for:b)
        XCTAssertTrue(first.hasPrefix("disk"),"Expected a stable BSD disk identifier, got \(first)")
        XCTAssertEqual(first,second)
    }
    func testIndependentLanesOverlapAndSameLaneRemainsSerial()throws {
        let lock=NSLock();var active=0,maxActive=0,byLane:[String:Int]=[:],maxLane=0
        let p=BoundedVerifier(maxConcurrentReads:2);p.testDelayPerChunk=0.01
        p.testWorkerObserver={ key,started in
            lock.lock();defer{lock.unlock()}
            active += started ? 1 : -1;byLane[key,default:0] += started ? 1 : -1
            maxActive=max(maxActive,active);maxLane=max(maxLane,byLane[key,default:0])
        }
        var urls:[URL]=[]
        for i in 0..<8 {
            let u=try file("lane-\(i).bin");urls.append(u)
            try p.submit(u,buffer:256*1024,isCancelled:{false},deviceKey:i<4 ? "a":"b",bounded:false)
        }
        for u in urls {
            let h=XXH64BE();h.update(data:try Data(contentsOf:u))
            XCTAssertEqual(try p.result(for:u),h.finalize().map{String(format:"%02x",$0)}.joined())
        }
        p.waitForAll()
        XCTAssertEqual(maxActive,2);XCTAssertEqual(maxLane,1)
        XCTAssertEqual(p.takeProgress().bytes,8*1024*1024)
    }
    func testReadFailureDoesNotDiscardOtherDestinationResult()throws {
        let p=BoundedVerifier(),good=try file("good.bin"),bad=root.appendingPathComponent("missing.bin")
        try p.submit(bad,buffer:4096,isCancelled:{false},deviceKey:"a",bounded:false)
        try p.submit(good,buffer:4096,isCancelled:{false},deviceKey:"b",bounded:false)
        XCTAssertThrowsError(try p.result(for:bad))
        let h=XXH64BE();h.update(data:try Data(contentsOf:good))
        XCTAssertEqual(try p.result(for:good),h.finalize().map{String(format:"%02x",$0)}.joined())
        p.waitForAll()
    }
    func testAfterCopyParallelPublishesOnlyMatchingChecksums()throws {
        let s=try file("parallel.bin",megabytes:16);let(e,a,b)=try engine(s)
        e.testCorruptTempBeforeVerify=true;e.start();wait{!e.isRunning}
        XCTAssertEqual(e.state,.failed);XCTAssertEqual(e.failCount,1);XCTAssertEqual(e.passCount,1)
        XCTAssertFalse(e.canSafeEject)
        let copies=[a,b].map{$0.appendingPathComponent(s.lastPathComponent)}
        XCTAssertEqual(copies.filter{FileManager.default.fileExists(atPath:$0.path)}.count,1)
        for u in copies where FileManager.default.fileExists(atPath:u.path) { XCTAssertEqual(try Data(contentsOf:u),try Data(contentsOf:s)) }
    }
    func testPauseAndResumeDuringParallelAfterCopy()throws {
        let s=try file("pause.bin",megabytes:32);let(e,a,b)=try engine(s)
        e.testHashDelayPerChunk=0.1;e.start()
        wait{e.state == .verifying && e.phaseBytes>0 && e.phaseProgress<1}
        e.pauseTransfer();XCTAssertTrue(e.isPaused)
        let settle=Date().addingTimeInterval(0.2)
        while Date()<settle {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
        let bytes=e.phaseBytes
        let hold=Date().addingTimeInterval(0.2)
        while Date()<hold {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
        XCTAssertEqual(e.phaseBytes,bytes);XCTAssertFalse(e.lastRunWasVerified)
        e.resumeTransfer();wait{!e.isRunning}
        XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.passCount,2)
        for d in [a,b] {XCTAssertEqual(try Data(contentsOf:d.appendingPathComponent(s.lastPathComponent)),try Data(contentsOf:s))}
    }
    func testCancelDrainsParallelWorkersAndRemovesTemporaryFiles()throws {
        let s=try file("cancel.bin",megabytes:32);let(e,a,b)=try engine(s)
        e.testHashDelayPerChunk=0.1;e.start();wait{e.state == .verifying && e.phaseBytes>0}
        e.pauseTransfer();e.cancel();wait{!e.isRunning}
        XCTAssertEqual(e.state,.cancelled);XCTAssertFalse(e.lastRunWasVerified)
        for d in [a,b] {
            let files=(FileManager.default.enumerator(at:d,includingPropertiesForKeys:nil)?.allObjects as? [URL]) ?? []
            XCTAssertFalse(files.contains{$0.lastPathComponent.hasPrefix(".nefcopy-partial-")})
            XCTAssertFalse(FileManager.default.fileExists(atPath:d.appendingPathComponent(s.lastPathComponent).path))
        }
    }
}
