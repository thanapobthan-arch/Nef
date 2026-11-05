import XCTest
import CryptoKit
@testable import NefCopy

final class AutomaticBufferTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopyAutoBuffer-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func wait(_ condition:()->Bool) {
        let end=Date().addingTimeInterval(45)
        while !condition() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.003))}
        XCTAssertTrue(condition(),"Timed out")
    }
    private func sha(_ file:URL)throws->SHA256.Digest {
        let h=try FileHandle(forReadingFrom:file);defer{try? h.close()};var hash=SHA256()
        while let data=try h.read(upToCount:8*1024*1024),!data.isEmpty {hash.update(data:data)}
        return hash.finalize()
    }
    private func mixed()throws->(URL,URL) {
        let source=root.appendingPathComponent("NewCard"),dest=root.appendingPathComponent("NewDest")
        for p in [source,dest] {try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true)}
        let big=source.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath:big.path,contents:nil))
        let h=try FileHandle(forWritingTo:big);try h.truncate(atOffset:UInt64(IOBufferSize.automaticLargeFileThreshold));try h.close()
        try Data(repeating:0x7A,count:1024*1024).write(to:source.appendingPathComponent("small.bin"))
        try Data().write(to:source.appendingPathComponent("empty"))
        return(source,dest)
    }
    func testThresholdAndLegacyCodableCompatibility()throws {
        let n=IOBufferSize.automaticLargeFileThreshold
        XCTAssertEqual(IOBufferSize.automatic.bytes(forFileSize:n-1),8*1024*1024)
        XCTAssertEqual(IOBufferSize.automatic.bytes(forFileSize:n),16*1024*1024)
        XCTAssertEqual(IOBufferSize.automatic.bytes(forFileSize:0),8*1024*1024)
        for raw in [4,8,16] {
            let mode=try JSONDecoder().decode(IOBufferSize.self,from:Data("\(raw)".utf8))
            XCTAssertEqual(mode.bytes(forFileSize:n+1),raw*1024*1024)
            XCTAssertEqual(try JSONEncoder().encode(mode),Data("\(raw)".utf8))
        }
        XCTAssertEqual(try JSONDecoder().decode(IOBufferSize.self,from:JSONEncoder().encode(IOBufferSize.automatic)),.automatic)
    }
    func testMixedFilesUseDifferentBuffersForIndependentReadCopyAndVerify()throws {
        let(s,d)=try mixed();let e=CopyEngine();e.sourceURLs=[s];e.destinations=[Destination(url:d)];e.independentSourceVerification=true
        var selections:[(String,Int)]=[];e.testBufferSelected={selections.append(($0,$1))}
        e.start();wait{!e.isRunning};XCTAssertTrue(e.lastRunWasVerified,e.errorMessage ?? "");XCTAssertEqual(e.passCount,3)
        for name in ["large.bin","small.bin","empty"] {
            let original=s.appendingPathComponent(name),copy=d.appendingPathComponent("NewCard/"+name)
            XCTAssertEqual(try sha(original),try sha(copy))
            let expected=(name == "large.bin" ? 16:8)*1024*1024
            let sourceSelections=selections.filter{$0.0==original.path}
            XCTAssertGreaterThanOrEqual(sourceSelections.count,2) // independent pre-read and copying
            XCTAssertTrue(sourceSelections.allSatisfy{$0.1==expected})
        }
        // Verification reads UUID-named private staging files, not final names.
        XCTAssertEqual(selections.filter{$0.0.hasPrefix(d.path) && $0.1==16*1024*1024}.count,1)
        XCTAssertEqual(selections.filter{$0.0.hasPrefix(d.path) && $0.1==8*1024*1024}.count,2)
        let report=try String(contentsOf:XCTUnwrap(e.lastReportURL))
        XCTAssertTrue(report.contains("I/O buffer policy: Automatic"));XCTAssertTrue(report.contains("FAIL: 0"))
    }
    func testPipelinedVerificationSelectsBufferForEachPendingFile()throws {
        let(s,d)=try mixed();let e=CopyEngine();e.sourceURLs=[s];e.destinations=[Destination(url:d)];e.verificationSchedule = .pipelined
        var selections:[(String,Int)]=[];e.testBufferSelected={selections.append(($0,$1))}
        e.start();wait{!e.isRunning};XCTAssertTrue(e.lastRunWasVerified,e.errorMessage ?? "")
        XCTAssertEqual(selections.filter{$0.0.hasPrefix(d.path) && $0.1==16*1024*1024}.count,1)
        XCTAssertEqual(selections.filter{$0.0.hasPrefix(d.path) && $0.1==8*1024*1024}.count,2)
        for name in ["large.bin","small.bin","empty"] {XCTAssertEqual(try sha(s.appendingPathComponent(name)),try sha(d.appendingPathComponent("NewCard/"+name)))}
    }
    func testSavedQueueKeepsAutomaticAndExistingFixedEightMegabytes()throws {
        let(s,d)=try mixed(),store=root.appendingPathComponent("queue.json")
        var q:TransferQueue?=TransferQueue(storageURL:store,startPaused:true)
        q!.enqueue(TransferJobSettings(sources:[s],destinations:[d]))
        q!.enqueue(TransferJobSettings(sources:[s],destinations:[d],buffer:.medium));q=nil
        let restored=TransferQueue(storageURL:store,startPaused:true)
        XCTAssertEqual(restored.jobs.map{$0.settings.buffer},[.automatic,.medium])
        XCTAssertEqual(restored.jobs[0].settings.buffer.bytes(forFileSize:IOBufferSize.automaticLargeFileThreshold),16*1024*1024)
        XCTAssertEqual(restored.jobs[1].settings.buffer.bytes(forFileSize:IOBufferSize.automaticLargeFileThreshold),8*1024*1024)
    }
    func testResumeKeepsSavedAutomaticPolicyWhenDraftSettingChanges()throws {
        let(s,d)=try mixed();let e=CopyEngine();e.sourceURLs=[s];e.destinations=[Destination(url:d)]
        e.testCopyDelayPerChunk=0.02;e.start();wait{e.sourceReadBytes>0};e.cancel();wait{!e.isRunning}
        e.ioBufferSize = .medium;e.testCopyDelayPerChunk=0
        var selections:[(String,Int)]=[];e.testBufferSelected={selections.append(($0,$1))}
        e.resumeTransfer();wait{!e.isRunning};XCTAssertTrue(e.lastRunWasVerified,e.errorMessage ?? "")
        XCTAssertTrue(selections.contains{$0.0==s.appendingPathComponent("large.bin").path && $0.1==16*1024*1024})
        XCTAssertEqual(try sha(s.appendingPathComponent("large.bin")),try sha(d.appendingPathComponent("NewCard/large.bin")))
    }
}
