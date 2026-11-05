import XCTest
@testable import NefCopy

final class NefCopyTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NefCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCanonicalFolderInventoryWithLinkedRootAndUnicodeChildren() throws {
        let card=try dir("การ์ด-日本語"), linked=root.appendingPathComponent("selected-alias")
        let source=try file("การ์ด-日本語/DCIM/ชั้นสอง/🎬.txt","new test data ภาษาไทย")
        try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:card)
        let a=try dir("dest-A"), b=try dir("dest-B"), e=CopyEngine()
        e.setSources([linked]);e.addDestinationURL(a);e.addDestinationURL(b)
        XCTAssertTrue(preflight(e).ok)
        e.start();waitUntil{!e.isRunning && e.state != .idle}
        XCTAssertTrue(e.lastRunWasVerified);XCTAssertEqual(e.failCount,0)
        for destination in [a,b] {
            let copied=destination.appendingPathComponent("การ์ด-日本語/DCIM/ชั้นสอง/🎬.txt")
            XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:copied))
        }
    }

    func testFolderInventoryDoesNotFollowFileOrDirectorySymlinks() throws {
        let card=try dir("card"), external=try file("outside/secret.txt","owned test fixture")
        _=try file("card/inside.txt","inside")
        try FileManager.default.createSymbolicLink(at:card.appendingPathComponent("file-link"),withDestinationURL:external)
        try FileManager.default.createSymbolicLink(at:card.appendingPathComponent("directory-link"),withDestinationURL:external.deletingLastPathComponent())
        let destination=try dir("dest"), e=CopyEngine()
        e.setSources([card]);e.addDestinationURL(destination);e.start()
        waitUntil{!e.isRunning && e.state != .idle}
        XCTAssertTrue(e.lastRunWasVerified)
        XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("card/inside.txt")),Data("inside".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathComponent("card/file-link").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathComponent("card/directory-link/secret.txt").path))
    }

    func testCancelledReportListsUnreachedFiles() throws {
        let a=try binaryFile("src/a.bin",megabytes:16)
        let b=try file("src/b.txt","not reached")
        let destination=try dir("cancel-report-destination")
        let e=CopyEngine();e.testCopyDelayPerChunk=0.2;e.setSources([a,b]);e.addDestinationURL(destination);e.start()
        waitUntil { e.copiedBytes>0 };e.cancel();waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.cancelled)
        let reports=try FileManager.default.contentsOfDirectory(at:destination.appendingPathComponent("NefCopy Reports"),includingPropertiesForKeys:nil)
        let report=try XCTUnwrap(reports.first{$0.lastPathComponent.hasSuffix("_report.txt")})
        let text=try String(contentsOf:report)
        XCTAssertTrue(text.contains("-- Not transferred --"))
        XCTAssertTrue(text.contains("Path: b.txt"))
        XCTAssertTrue(text.contains("Size: 11 bytes"))
        XCTAssertTrue(text.contains("NOT FULLY VERIFIED"))
    }

    func testPauseResumeKeepsSourceReadOffset() throws {
        let source=try binaryFile("pause.bin",megabytes:32), destination=try dir("pause-dest")
        let e=CopyEngine();e.testCopyDelayPerChunk=0.1;e.setSources([source]);e.addDestinationURL(destination);e.start()
        waitUntil { e.copiedBytes>0 };e.pauseTransfer()
        XCTAssertTrue(e.isPaused);XCTAssertTrue(e.canResume)
        let settle=Date().addingTimeInterval(0.3)
        while Date()<settle { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        let bytes=e.copiedBytes,progress=e.progress
        let hold=Date().addingTimeInterval(0.2)
        while Date()<hold { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(e.copiedBytes,bytes)
        e.resumeTransfer();XCTAssertFalse(e.isPaused);XCTAssertGreaterThanOrEqual(e.progress,progress)
        waitUntil { !e.isRunning };XCTAssertEqual(e.state,.completed)
        XCTAssertEqual(e.testSourceBytesRead,32*1024*1024)
        XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:destination.appendingPathComponent("pause.bin")))
    }
    func testPauseDuringVerifyDoesNotRecopy() throws {
        let source=try binaryFile("pause-verify.bin",megabytes:32),destination=try dir("pause-verify")
        let e=CopyEngine();e.testHashDelayPerChunk=0.1;e.setSources([source]);e.addDestinationURL(destination);e.start()
        waitUntil { e.state == .verifying && e.phaseProgress>0 && e.phaseProgress<1 }
        e.pauseTransfer();XCTAssertTrue(e.isPaused)
        let hold=Date().addingTimeInterval(0.3)
        while Date()<hold { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(e.isPaused);XCTAssertFalse(e.lastRunWasVerified)
        e.resumeTransfer();waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.testSourceBytesRead,32*1024*1024)
        XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:destination.appendingPathComponent("pause-verify.bin")))
    }
    func testCancelUnblocksPausedWorker() throws {
        let source=try binaryFile("pause-cancel.bin",megabytes:32),destination=try dir("pause-cancel")
        let e=CopyEngine();e.testCopyDelayPerChunk=0.1;e.setSources([source]);e.addDestinationURL(destination);e.start()
        waitUntil { e.copiedBytes>0 };e.pauseTransfer();e.cancel()
        waitUntil { !e.isRunning };XCTAssertEqual(e.state,.cancelled);XCTAssertFalse(e.isPaused)
    }

    private func file(_ rel: String, _ data: String) throws -> URL {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data.utf8).write(to: u); return u
    }
    private func binaryFile(_ rel:String, megabytes:Int) throws -> URL {
        let u=root.appendingPathComponent(rel); try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true)
        FileManager.default.createFile(atPath:u.path,contents:nil); let h=try FileHandle(forWritingTo:u); defer{try? h.close()}
        let block=Data(repeating:0xA5,count:1024*1024); for _ in 0..<megabytes { try h.write(contentsOf:block) }; return u
    }
    private func dir(_ rel:String) throws -> URL { let u=root.appendingPathComponent(rel,isDirectory:true); try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true); return u }
    private func waitUntil(_ timeout: TimeInterval = 12, _ condition: @escaping () -> Bool) {
        let end=Date().addingTimeInterval(timeout); while Date()<end && !condition(){ RunLoop.main.run(until:Date().addingTimeInterval(0.03)) }
    }
    private func preflight(_ e:CopyEngine)->PreflightResult { let x=expectation(description:"preflight"); var out=PreflightResult(ok:false,messages:["timeout"]); e.runPreflight{out=$0;x.fulfill()}; wait(for:[x],timeout:12); return out }
    private func partials(in u:URL)->[URL] { (FileManager.default.enumerator(at:u,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []).filter{$0.lastPathComponent.hasPrefix(".nefcopy-partial-")} }

    func testNormalCopyAndVerify() throws { let s=try file("source/a.txt","hello"), d=try dir("dest"); let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.failCount,0);XCTAssertTrue(e.lastRunWasVerified);XCTAssertEqual(try String(contentsOf:d.appendingPathComponent("a.txt")),"hello") }
    func testVerifyOffIsClearlyNotVerifiedAndCannotSafeEject() throws { let s=try file("source/a.txt","hello"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.verifyEnabled=false;e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed);XCTAssertFalse(e.lastRunWasVerified);XCTAssertFalse(e.canSafeEject);XCTAssertTrue(e.statusText.contains("NOT VERIFIED")) }
    func testDuplicateIdenticalIsSkipped() throws { let s=try file("source/a.txt","same"),d=try dir("dest");try Data("same".utf8).write(to:d.appendingPathComponent("a.txt"));let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);let r=preflight(e);XCTAssertTrue(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("SKIP — IDENTICAL")}) }
    func testDuplicateConflictBlocksAndPreservesExistingFile() throws { let s=try file("source/a.txt","NEW"),d=try dir("dest"),t=d.appendingPathComponent("a.txt");try Data("OLD-DO-NOT-TOUCH".utf8).write(to:t);let before=try Data(contentsOf:t);let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);XCTAssertFalse(preflight(e).ok);e.start();waitUntil{e.state == .failed};XCTAssertEqual(try Data(contentsOf:t),before);XCTAssertEqual(e.state,.failed) }
    func testMultipleDestinations() throws { let s=try file("source/a.txt","multi"),d1=try dir("d1"),d2=try dir("d2");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d1);e.addDestinationURL(d2);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed);XCTAssertTrue(FileManager.default.fileExists(atPath:d1.appendingPathComponent("a.txt").path));XCTAssertTrue(FileManager.default.fileExists(atPath:d2.appendingPathComponent("a.txt").path)) }
    func testDestinationInsideSourceBlocked() throws { let s=try dir("card");_=try file("card/a.txt","x");let d=try dir("card/backup");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);XCTAssertFalse(preflight(e).ok) }
    func testSourceInsideDestinationBlocked() throws { let d=try dir("drive"),s=try dir("drive/card");_=try file("drive/card/a.txt","x");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);XCTAssertFalse(preflight(e).ok) }
    func testMultipleSourceNameCollisionBlocked() throws { let a=try file("A/clip.mov","AAA"),b=try file("B/clip.mov","BBB"),d=try dir("dest");let e=CopyEngine();e.setSources([a,b]);e.addDestinationURL(d);let r=preflight(e);XCTAssertFalse(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("collision")}) }
    func testCancelCleansPartialThenResumeCompletes() throws { let s=try binaryFile("source/big.bin",megabytes:32),d=try dir("dest");let e=CopyEngine();e.testCopyDelayPerChunk=0.04;e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil(3){e.copiedBytes>0};e.cancel();waitUntil(6){e.state == .cancelled};XCTAssertEqual(e.state,.cancelled);XCTAssertTrue(partials(in:d).isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:d.appendingPathComponent("big.bin").path));XCTAssertTrue(e.canResume);e.testCopyDelayPerChunk=0;e.resumeTransfer();waitUntil(12){!e.isRunning && e.state != .cancelled};XCTAssertEqual(e.state,.completed);XCTAssertTrue(FileManager.default.fileExists(atPath:d.appendingPathComponent("big.bin").path));XCTAssertTrue(partials(in:d).isEmpty) }
    func testRetryFailedOnly() throws { let good=try file("src/good.txt","good"),bad=try file("src/bad.txt","bad"),d=try dir("dest");let e=CopyEngine();e.setSources([good,bad]);e.addDestinationURL(d);e.testFailCopyOncePaths=[bad.path];e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.failed);XCTAssertTrue(e.canRetryFailed);let goodDate=try FileManager.default.attributesOfItem(atPath:d.appendingPathComponent("good.txt").path)[.modificationDate] as? Date;Thread.sleep(forTimeInterval:0.05);e.retryFailed();waitUntil{!e.isRunning && e.state != .failed};XCTAssertEqual(e.state,.completed);XCTAssertEqual(try String(contentsOf:d.appendingPathComponent("bad.txt")),"bad");let goodDate2=try FileManager.default.attributesOfItem(atPath:d.appendingPathComponent("good.txt").path)[.modificationDate] as? Date;XCTAssertEqual(goodDate,goodDate2,"Retry Failed Only must not rewrite successful files") }
    func testReportsGeneratedInsideEveryDestination() throws { let source=try file("source/a.txt","report"),d1=try dir("d1"),d2=try dir("d2");let e=CopyEngine();e.setSources([source]);e.addDestinationURL(d1);e.addDestinationURL(d2);e.start();waitUntil{!e.isRunning && e.state != .idle};for d in [d1,d2]{let names=try FileManager.default.contentsOfDirectory(atPath:d.appendingPathComponent("NefCopy Reports").path).filter{$0.hasSuffix("_report.txt")};XCTAssertEqual(names.count,1);XCTAssertTrue(names.allSatisfy{$0.hasSuffix("_report.txt")});XCTAssertTrue(names[0].contains("source"))} }
    func testTextReportIncludesSourceFoldersAndSpecialCharacters() throws { let source=try file("A&B/clip.txt","x"),out=root.appendingPathComponent("report.txt");let e=CopyEngine();try e.writeTextReport(records:[],started:Date(),status:"CANCELLED",bytes:1,files:1,verified:true,sources:[source],destinations:[],to:out);let text=try String(contentsOf:out);XCTAssertTrue(text.contains("Source folders: A&B"));XCTAssertTrue(text.contains("Pending/unreported: 1"));XCTAssertTrue(text.contains("NOT FULLY VERIFIED")) }
    func testNoPartialFilesAfterSuccessfulCopy() throws { let s=try file("source/a.txt","clean"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed);XCTAssertTrue(partials(in:d).isEmpty) }
    func testStartRechecksConflictEvenWithoutPreflight() throws { let s=try file("source/a.txt","NEW"),d=try dir("dest");try Data("OLD".utf8).write(to:d.appendingPathComponent("a.txt"));let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{e.state == .failed};XCTAssertEqual(try String(contentsOf:d.appendingPathComponent("a.txt")),"OLD") }
    func testVerifiedManifestCreatedAndSecondPreflightUsesCache() throws {
        let s=try file("source/a.txt","manifest-cache"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed)
        let manifest=d.appendingPathComponent("NefCopy Reports/.nefcopy_manifest.json");XCTAssertTrue(FileManager.default.fileExists(atPath:manifest.path))
        let r=preflight(e);XCTAssertTrue(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("cached verified XXH64BE")});XCTAssertEqual(e.preflightProgress,1,accuracy:0.001)
    }
    func testManifestInvalidatesWhenDestinationMetadataChanges() throws {
        let s=try file("source/a.txt","ORIGINAL"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed)
        let t=d.appendingPathComponent("a.txt");try Data("CHANGED!".utf8).write(to:t);let r=preflight(e);XCTAssertFalse(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("FAIL — CONFLICT")})
    }
    func testPreflightProgressReachesOneForMultipleFiles() throws {
        let folder=try dir("source");for i in 0..<8 { _ = try file("source/f\(i).txt","x\(i)") };let d=try dir("dest");let e=CopyEngine();e.setSources([folder]);e.addDestinationURL(d);let r=preflight(e);XCTAssertTrue(r.ok);XCTAssertEqual(e.preflightProgress,1,accuracy:0.001);XCTAssertTrue(e.preflightStatus.contains("100%"))
    }

    // MARK: - v18 expanded reliability regression suite
    func testEmptyPreflightBlocked() { let e=CopyEngine();let r=preflight(e);XCTAssertFalse(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("No source")}) }
    func testSourceWithoutDestinationBlocked() throws { let s=try file("src/a.txt","a");let e=CopyEngine();e.setSources([s]);let r=preflight(e);XCTAssertFalse(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("No destination")}) }
    func testDestinationWithoutSourceBlocked() throws { let d=try dir("dest");let e=CopyEngine();e.addDestinationURL(d);let r=preflight(e);XCTAssertFalse(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("No source")}) }
    func testDuplicateDestinationIsNotAddedTwice() throws { let d=try dir("dest");let e=CopyEngine();e.addDestinationURL(d);e.addDestinationURL(d);XCTAssertEqual(e.destinations.count,1) }
    func testDuplicateSourceIsNotAddedTwice() throws { let s=try file("src/a.txt","a");let e=CopyEngine();e.addSourceURL(s);e.addSourceURL(s);XCTAssertEqual(e.sourceURLs.count,1) }
    func testClearSourcesResetsCountsAndPrompt() throws { let s=try file("src/a.txt","abc");let e=CopyEngine();e.setSources([s]);waitUntil{e.totalFiles==1};e.clearSources();XCTAssertTrue(e.sourceURLs.isEmpty);XCTAssertEqual(e.totalFiles,0);XCTAssertEqual(e.totalBytes,0);XCTAssertTrue(e.statusText.contains("Drop files")) }
    func testRemoveSourceUpdatesSourceList() throws { let a=try file("src/a.txt","a"),b=try file("src/b.txt","b");let e=CopyEngine();e.setSources([a,b]);e.removeSource(a);XCTAssertEqual(e.sourceURLs,[b]) }
    func testRemoveDestinationUpdatesList() throws { let d1=try dir("d1"),d2=try dir("d2");let e=CopyEngine();e.addDestinationURL(d1);e.addDestinationURL(d2);let first=e.destinations[0];e.removeDestination(first);XCTAssertEqual(e.destinations.count,1);XCTAssertEqual(e.destinations[0].url,d2) }
    func testSingleSourceName() throws { let s=try file("src/clip.mov","x");let e=CopyEngine();e.setSources([s]);XCTAssertEqual(e.sourceName,"clip.mov") }
    func testMultipleSourceNameShowsItemCount() throws { let a=try file("src/a.txt","a"),b=try file("src/b.txt","b");let e=CopyEngine();e.setSources([a,b]);XCTAssertEqual(e.sourceName,"2 items") }
    func testSourceScanCountsFilesAndBytes() throws { let f=try dir("card");_=try file("card/a.txt","123");_=try file("card/b.txt","4567");let e=CopyEngine();e.setSources([f]);waitUntil{e.totalFiles==2};XCTAssertEqual(e.totalFiles,2);XCTAssertEqual(e.totalBytes,7) }
    func testHiddenFilesAreSkippedDuringFolderScan() throws { let f=try dir("card");_=try file("card/a.txt","1");_=try file("card/.hidden","12345");let e=CopyEngine();e.setSources([f]);waitUntil{e.totalFiles>0};XCTAssertEqual(e.totalFiles,1);XCTAssertEqual(e.totalBytes,1) }
    func testNestedFolderStructurePreserved() throws { let f=try dir("CARD");_=try file("CARD/DCIM/100MEDIA/a.txt","nested");let d=try dir("dest");let e=CopyEngine();e.setSources([f]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(try String(contentsOf:d.appendingPathComponent("CARD/DCIM/100MEDIA/a.txt")),"nested") }
    func testEmptyFileCopiesAndVerifies() throws { let s=try file("src/empty.bin",""),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed);XCTAssertEqual((try Data(contentsOf:d.appendingPathComponent("empty.bin"))).count,0) }
    func testUnicodeFilenameCopies() throws { let s=try file("src/ไฟล์-日本語-🎬.txt","unicode"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(try String(contentsOf:d.appendingPathComponent(s.lastPathComponent)),"unicode") }
    func testSpacesAndSpecialCharactersFilenameCopies() throws { let s=try file("src/A & B (final) #1.txt","special"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(try String(contentsOf:d.appendingPathComponent(s.lastPathComponent)),"special") }
    func testCaseInsensitiveSourceCollisionBlocked() throws { let a=try file("A/CLIP.MOV","A"),b=try file("B/clip.mov","B"),d=try dir("dest");let e=CopyEngine();e.setSources([a,b]);e.addDestinationURL(d);XCTAssertFalse(preflight(e).ok) }
    func testCanonicalUnicodeSourceCollisionBlocked() throws { let a=try file("A/café.txt","A"),b=try file("B/cafe\u{301}.txt","B"),d=try dir("dest");let e=CopyEngine();e.setSources([a,b]);e.addDestinationURL(d);XCTAssertFalse(preflight(e).ok) }
    func testIdenticalExistingFileNotRewrittenOnStart() throws { let s=try file("src/a.txt","same"),d=try dir("dest"),t=d.appendingPathComponent("a.txt");try Data("same".utf8).write(to:t);let before=try FileManager.default.attributesOfItem(atPath:t.path)[.modificationDate] as? Date;Thread.sleep(forTimeInterval:0.05);let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};let after=try FileManager.default.attributesOfItem(atPath:t.path)[.modificationDate] as? Date;XCTAssertEqual(before,after);XCTAssertEqual(e.state,.completed) }
    func testConflictAtOneDestinationBlocksAllBeforeCopy() throws { let s=try file("src/a.txt","NEW"),d1=try dir("d1"),d2=try dir("d2");try Data("OLD".utf8).write(to:d2.appendingPathComponent("a.txt"));let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d1);e.addDestinationURL(d2);e.start();waitUntil{e.state == .failed};XCTAssertFalse(FileManager.default.fileExists(atPath:d1.appendingPathComponent("a.txt").path));XCTAssertEqual(try String(contentsOf:d2.appendingPathComponent("a.txt")),"OLD") }
    func testVerifyOffStillBlocksDifferentDuplicate() throws { let s=try file("src/a.txt","NEW"),d=try dir("dest");try Data("OLD".utf8).write(to:d.appendingPathComponent("a.txt"));let e=CopyEngine();e.verifyEnabled=false;e.setSources([s]);e.addDestinationURL(d);XCTAssertFalse(preflight(e).ok) }
    func testVerifyOffPreflightWarnsClearly() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.verifyEnabled=false;e.setSources([s]);e.addDestinationURL(d);let r=preflight(e);XCTAssertTrue(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("verification is OFF")}) }
    func testVerifiedRunEnablesSafeEject() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertTrue(e.canSafeEject) }
    func testFailedRunDoesNotEnableSafeEject() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.testFailCopyOncePaths=[s.path];e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.canSafeEject) }
    func testCancelledRunDoesNotEnableSafeEject() throws { let s=try binaryFile("src/big.bin",megabytes:16),d=try dir("dest");let e=CopyEngine();e.testCopyDelayPerChunk=0.05;e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil(3){e.copiedBytes>0};e.cancel();waitUntil{e.state == .cancelled};XCTAssertFalse(e.canSafeEject) }
    func testProgressFinishesAtOne() throws { let s=try file("src/a.txt","progress"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.progress,1,accuracy:0.0001) }
    func testCompletedFileCountForThreeFiles() throws { let f=try dir("src");for i in 0..<3 { _=try file("src/f\(i).txt","\(i)") };let d=try dir("dest");let e=CopyEngine();e.setSources([f]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.completedFiles,3);XCTAssertEqual(e.passCount,3);XCTAssertEqual(e.failCount,0) }
    func testManifestCorruptionFallsBackSafely() throws { let s=try file("src/a.txt","same"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};let m=d.appendingPathComponent("NefCopy Reports/.nefcopy_manifest.json");try Data("not-json".utf8).write(to:m);let r=preflight(e);XCTAssertTrue(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("SKIP — IDENTICAL") && !$0.contains("cached")}) }
    func testMissingManifestFallsBackSafely() throws { let s=try file("src/a.txt","same"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};try FileManager.default.removeItem(at:d.appendingPathComponent("NefCopy Reports/.nefcopy_manifest.json"));let r=preflight(e);XCTAssertTrue(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("SKIP — IDENTICAL") && !$0.contains("cached")}) }
    func testSourceMetadataChangeInvalidatesManifestCache() throws { let s=try file("src/a.txt","ORIGINAL"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};Thread.sleep(forTimeInterval:0.02);try Data("CHANGED!".utf8).write(to:s);let r=preflight(e);XCTAssertFalse(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("CONFLICT")}) }
    func testManifestIsValidJSON() throws { let s=try file("src/a.txt","json"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};let data=try Data(contentsOf:d.appendingPathComponent("NefCopy Reports/.nefcopy_manifest.json"));XCTAssertNoThrow(try JSONSerialization.jsonObject(with:data)) }
    func testManifestContainsRelativePathAndHash() throws { let s=try file("src/a.txt","manifest"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};let text=try String(contentsOf:d.appendingPathComponent("NefCopy Reports/.nefcopy_manifest.json"));XCTAssertTrue(text.contains("a.txt"));XCTAssertTrue(text.contains("checksum")) }
    func testReportsDirectoryContainsManifestAfterVerifiedRun() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertTrue(FileManager.default.fileExists(atPath:d.appendingPathComponent("NefCopy Reports/.nefcopy_manifest.json").path)) }
    func testVerifyOffDoesNotCreateTrustedManifestEntry() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.verifyEnabled=false;e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};let r=preflight(e);XCTAssertTrue(r.ok);XCTAssertFalse(r.messages.contains{$0.contains("cached verified XXH64BE")}) }
    func testTextReportEscapesNewlinesInFileRows() throws {
        let source=try file("src/a.txt","x"),out=root.appendingPathComponent("report.txt")
        let record=ChecksumRecord(file:"clip\nPASS.txt",source:source.path,destination:"/d/x",sourceChecksum:"a",destinationChecksum:"a",status:"PASS")
        let e=CopyEngine();try e.writeTextReport(records:[record],started:Date(),status:"COMPLETED / VERIFIED",bytes:1,files:1,verified:true,sources:[source],destinations:[],to:out)
        let text=try String(contentsOf:out)
        XCTAssertTrue(text.contains("Path: clip\\nPASS.txt"))
        XCTAssertFalse(text.contains("Path: clip\nPASS.txt"))
    }

    func testTextReportShowsVerifiedStatus() throws { let source=try file("src/a.txt","x"),out=root.appendingPathComponent("report.txt");let record=ChecksumRecord(file:"a.txt",source:source.path,destination:"/d/a.txt",sourceChecksum:"a",destinationChecksum:"a",status:"PASS");let e=CopyEngine();try e.writeTextReport(records:[record],started:Date(),status:"COMPLETED / VERIFIED",bytes:1,files:1,verified:true,sources:[source],destinations:[],to:out);let text=try String(contentsOf:out);XCTAssertTrue(text.contains("Result: VERIFIED"));XCTAssertTrue(text.contains("PASS: 1"));XCTAssertTrue(text.contains("FAIL: 0")) }
    func testTextReportShowsNotVerifiedStatus() throws { let source=try file("src/a.txt","x"),out=root.appendingPathComponent("report.txt");let record=ChecksumRecord(file:"a.txt",source:source.path,destination:"/d/a.txt",sourceChecksum:"Not verified",destinationChecksum:"Not verified",status:"COPIED");let e=CopyEngine();try e.writeTextReport(records:[record],started:Date(),status:"COMPLETED / NOT VERIFIED",bytes:1,files:1,verified:false,sources:[source],destinations:[],to:out);let text=try String(contentsOf:out);XCTAssertTrue(text.contains("Result: NOT FULLY VERIFIED"));XCTAssertTrue(text.contains("COPIED / NOT VERIFIED: 1")) }
    func testSecondVerifiedRunUsesManifestAndCompletes() throws { let s=try file("src/a.txt","cache"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.failCount,0) }
    func testRetryUnavailableAfterSuccess() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertFalse(e.canRetryFailed);XCTAssertFalse(e.canResume) }
    func testResumeUnavailableBeforeAnyRun() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);XCTAssertFalse(e.canResume) }
    func testPreflightProgressIsOneWhenBlockedEarly() { let e=CopyEngine();_=preflight(e);XCTAssertEqual(e.preflightProgress,1,accuracy:0.001);XCTAssertEqual(e.preflightStatus,"Pre-flight blocked") }
    func testPreflightMultipleDestinationsReachesHundredPercent() throws { let f=try dir("src");for i in 0..<4 { _=try file("src/f\(i).txt","x") };let d1=try dir("d1"),d2=try dir("d2");let e=CopyEngine();e.setSources([f]);e.addDestinationURL(d1);e.addDestinationURL(d2);let r=preflight(e);XCTAssertTrue(r.ok);XCTAssertEqual(e.preflightProgress,1,accuracy:0.001);XCTAssertTrue(e.preflightStatus.contains("100%")) }
    func testPreflightReportsNoExistingDestinationFiles() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);let r=preflight(e);XCTAssertTrue(r.messages.contains{$0.contains("no existing destination files")}) }
    func testPreflightReportsIdenticalCount() throws { let f=try dir("src");_=try file("src/a.txt","a");_=try file("src/b.txt","b");let d=try dir("dest");try FileManager.default.createDirectory(at:d.appendingPathComponent("src"),withIntermediateDirectories:true);try Data("a".utf8).write(to:d.appendingPathComponent("src/a.txt"));try Data("b".utf8).write(to:d.appendingPathComponent("src/b.txt"));let e=CopyEngine();e.setSources([f]);e.addDestinationURL(d);let r=preflight(e);XCTAssertTrue(r.ok);XCTAssertTrue(r.messages.contains{$0.contains("2 identical existing file(s)")}) }
    func testManySmallFilesCopy() throws { let f=try dir("src");for i in 0..<100 { _=try file("src/f\(i).txt","value-\(i)") };let d=try dir("dest");let e=CopyEngine();e.setSources([f]);e.addDestinationURL(d);e.start();waitUntil(20){!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.completedFiles,100);XCTAssertTrue(partials(in:d).isEmpty) }
    func testTwoDestinationsReceiveIdenticalBytes() throws { let s=try binaryFile("src/data.bin",megabytes:2),d1=try dir("d1"),d2=try dir("d2");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d1);e.addDestinationURL(d2);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(try Data(contentsOf:d1.appendingPathComponent("data.bin")),try Data(contentsOf:d2.appendingPathComponent("data.bin"))) }
    func testFailureLeavesNoPartialFiles() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.testFailCopyOncePaths=[s.path];e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.failed);XCTAssertTrue(partials(in:d).isEmpty) }
    func testFailureDoesNotCreateFinalTarget() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.testFailCopyOncePaths=[s.path];e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertFalse(FileManager.default.fileExists(atPath:d.appendingPathComponent("a.txt").path)) }
    func testRetryAfterSingleInjectedFailureBecomesVerified() throws { let s=try file("src/a.txt","x"),d=try dir("dest");let e=CopyEngine();e.setSources([s]);e.addDestinationURL(d);e.testFailCopyOncePaths=[s.path];e.start();waitUntil{!e.isRunning && e.state != .idle};e.retryFailed();waitUntil{!e.isRunning && e.state != .failed};XCTAssertEqual(e.state,.completed);XCTAssertTrue(e.lastRunWasVerified) }

    func testSingleReadFanOutCopiesToTwoDestinations() throws { let s=try binaryFile("src/fan.bin",megabytes:2),d1=try dir("fan1"),d2=try dir("fan2");let e=CopyEngine();e.transferStrategy = .singleReadFanOut;e.setSources([s]);e.addDestinationURL(d1);e.addDestinationURL(d2);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed);XCTAssertEqual(try Data(contentsOf:d1.appendingPathComponent("fan.bin")),try Data(contentsOf:d2.appendingPathComponent("fan.bin")));XCTAssertEqual(e.failCount,0) }
    func testSingleReadFanOutVerifyOffCopiesBoth() throws { let s=try file("src/f.txt","fanout"),d1=try dir("fo1"),d2=try dir("fo2");let e=CopyEngine();e.transferStrategy = .singleReadFanOut;e.verifyEnabled=false;e.setSources([s]);e.addDestinationURL(d1);e.addDestinationURL(d2);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertEqual(e.state,.completed);XCTAssertFalse(e.lastRunWasVerified);XCTAssertEqual(try String(contentsOf:d1.appendingPathComponent("f.txt")),"fanout");XCTAssertEqual(try String(contentsOf:d2.appendingPathComponent("f.txt")),"fanout") }
    func testSingleReadFanOutLeavesNoPartials() throws { let s=try binaryFile("src/f.bin",megabytes:1),d1=try dir("fp1"),d2=try dir("fp2");let e=CopyEngine();e.transferStrategy = .singleReadFanOut;e.setSources([s]);e.addDestinationURL(d1);e.addDestinationURL(d2);e.start();waitUntil{!e.isRunning && e.state != .idle};XCTAssertTrue(partials(in:d1).isEmpty);XCTAssertTrue(partials(in:d2).isEmpty) }
    func testTransferStrategyDefaultsToSingleReadFanOut() { let e=CopyEngine();XCTAssertEqual(e.transferStrategy,.singleReadFanOut) }

    func testClearDestinationsRemovesAllDestinations() throws {
        let d1 = try dir("clear-d1")
        let d2 = try dir("clear-d2")
        let e = CopyEngine()
        e.addDestinationURL(d1)
        e.addDestinationURL(d2)
        XCTAssertEqual(e.destinations.count, 2)
        e.clearDestinations()
        XCTAssertTrue(e.destinations.isEmpty)
    }


    func testV20Stage1StartChecksDestinationSpaceBeforeCopying() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "/Tests/NefCopyTests/NefCopyTests.swift", with: "/Sources/NefCopy/CopyEngine.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("self.filesystemCapacity(for:d.url)"))
        XCTAssertTrue(source.contains("attributesOfFileSystem(forPath:url.path)"))
        XCTAssertTrue(source.contains("if mode == .normal"))
        XCTAssertTrue(source.contains("Check every run, including Resume/Retry"))
        XCTAssertTrue(source.contains("CopyError.insufficientSpace"))
    }


    func testV20Stage2ContainsSourceDisconnectDetection() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "/Tests/NefCopyTests/NefCopyTests.swift", with: "/Sources/NefCopy/CopyEngine.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("NSWorkspace.didUnmountNotification"))
        XCTAssertTrue(source.contains("Source Disconnected"))
        XCTAssertTrue(source.contains("sourceURLs.contains{ sameVolume"))
    }

    func testV20Stage2ContainsDestinationDisconnectDetection() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "/Tests/NefCopyTests/NefCopyTests.swift", with: "/Sources/NefCopy/CopyEngine.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Destination Disconnected"))
        XCTAssertTrue(source.contains("destinations + resumeDestinations"))
        XCTAssertTrue(source.contains("cancelled=true"))
    }


    func testV20Stage3ContainsSleepPreventionLifecycle() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "/Tests/NefCopyTests/NefCopyTests.swift", with: "/Sources/NefCopy/CopyEngine.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("ProcessInfo.processInfo.beginActivity"))
        XCTAssertTrue(source.contains(".idleSystemSleepDisabled"))
        XCTAssertTrue(source.contains("ProcessInfo.processInfo.endActivity"))
        XCTAssertTrue(source.contains("self.stopSleepPrevention(); self.lastReportURL=report"))
    }


    func testV201QuitsAfterLastWindowCloses() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "/Tests/NefCopyTests/NefCopyTests.swift", with: "/Sources/NefCopy/NefCopyApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("applicationShouldTerminateAfterLastWindowClosed"))
        XCTAssertTrue(source.contains("true"))
    }


    func testV202RAIDCapacityUsesFilesystemAttributesAndInt64() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "/Tests/NefCopyTests/NefCopyTests.swift", with: "/Sources/NefCopy/CopyEngine.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("attributesOfFileSystem(forPath:url.path)"))
        XCTAssertTrue(source.contains("attrs[.systemSize] as? NSNumber"))
        XCTAssertTrue(source.contains("attrs[.systemFreeSize] as? NSNumber"))
        XCTAssertTrue(source.contains("freeNumber.int64Value"))
        XCTAssertTrue(source.contains("guard total > 0, available >= 0"))
    }

    func testV202LargeRAIDValuesFitInt64() {
        let sixtyTB:Int64 = 60_000_000_000_000
        let free:Int64 = 52_640_000_000_000
        XCTAssertGreaterThan(sixtyTB, 0)
        XCTAssertGreaterThan(free, 0)
        XCTAssertLessThan(free, sixtyTB)
    }


    func testV203PreflightUsesRAIDSafeFilesystemCapacity() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "/Tests/NefCopyTests/NefCopyTests.swift", with: "/Sources/NefCopy/CopyEngine.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("func freeSpace(for u:URL)->Int64?"))
        XCTAssertTrue(source.contains("filesystemCapacity(for:u)?.available"))
    }

    func testV204StandardHashesSourceDuringCopyOnly() throws {
        let source=try binaryFile("one-pass.bin",megabytes:12), destination=try dir("one-pass-dest")
        let e=CopyEngine(); e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        XCTAssertEqual(e.state,.completed)
        XCTAssertEqual(e.testSourceBytesRead,12*1024*1024)
        XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:destination.appendingPathComponent("one-pass.bin")))
    }
    func testV204VerifyPublishesPartialProgress() throws {
        let source=try binaryFile("verify.bin",megabytes:32), destination=try dir("verify-dest")
        let e=CopyEngine(); e.testHashDelayPerChunk=0.05; e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil(5) { e.phaseName == "Verifying destination" && e.phaseProgress>0 && e.phaseProgress<1 }
        XCTAssertEqual(e.state,.verifying)
        XCTAssertGreaterThan(e.phaseBytes,0)
        XCTAssertLessThan(e.progress,1)
        XCTAssertGreaterThan(e.speedBytesPerSecond,0)
        waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.completed)
        XCTAssertEqual(e.progress,1)
    }
    func testV204FanOutCancelDuringVerifyCleansAllPartials() throws {
        let source=try binaryFile("fan-cancel.bin",megabytes:32), d1=try dir("fan-cancel-1"), d2=try dir("fan-cancel-2")
        let e=CopyEngine(); e.transferStrategy = .singleReadFanOut; e.testHashDelayPerChunk=0.05
        e.setSources([source]); e.addDestinationURL(d1); e.addDestinationURL(d2); e.start()
        waitUntil(5) { e.phaseName == "Verifying destination" && e.phaseProgress>0 && e.phaseProgress<1 }
        XCTAssertEqual(e.state,.verifying); e.cancel()
        waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.cancelled)
        XCTAssertFalse(e.canSafeEject)
        XCTAssertTrue(partials(in:d1).isEmpty); XCTAssertTrue(partials(in:d2).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d1.appendingPathComponent("fan-cancel.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:d2.appendingPathComponent("fan-cancel.bin").path))
    }
    func testV204DuplicateManifestPathsFallBackToHash() throws {
        let source=try file("manifest-src.txt","same"), destination=try dir("manifest-duplicate")
        let e=CopyEngine(); e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        let manifest=destination.appendingPathComponent("NefCopy Reports/.nefcopy_manifest.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        var entries=try XCTUnwrap(json["entries"] as? [[String:Any]])
        entries.append(try XCTUnwrap(entries.first)); json["entries"]=entries
        try JSONSerialization.data(withJSONObject:json).write(to:manifest)
        let result=preflight(e)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.messages.contains { $0.contains("SKIP — IDENTICAL") && !$0.contains("cached") })
    }

    func testV2041OverallETAIncludesRemainingFilesDuringVerify() throws {
        let source=try dir("eta-source")
        _=try binaryFile("eta-source/a.bin",megabytes:32)
        _=try binaryFile("eta-source/b.bin",megabytes:32)
        let destination=try dir("eta-destination")
        let e=CopyEngine(); e.testCopyDelayPerChunk=0.03; e.testHashDelayPerChunk=0.05
        e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil(5) { e.phaseName == "Verifying destination" && e.phaseProgress>0 && e.phaseProgress<1 && e.completedFiles==0 }
        XCTAssertEqual(e.state,.verifying)
        XCTAssertTrue(e.overallEtaSeconds.isFinite)
        XCTAssertGreaterThan(e.overallEtaSeconds,0)
        XCTAssertGreaterThan(e.overallEtaSeconds,e.etaSeconds)
        waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.completed)
        XCTAssertEqual(e.overallEtaSeconds,0)
    }
    func testV2041OverallETAClearsAfterCancel() throws {
        let source=try binaryFile("eta-cancel.bin",megabytes:32), destination=try dir("eta-cancel-dest")
        let e=CopyEngine(); e.testCopyDelayPerChunk=0.05
        e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil(5) { e.copiedBytes>0 && e.overallEtaSeconds>0 }
        XCTAssertGreaterThan(e.overallEtaSeconds,0)
        e.cancel(); waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.cancelled)
        XCTAssertEqual(e.overallEtaSeconds,0)
    }

    func testV205XXH64BEKnownVectors() {
        let vectors:[(Data,String)]=[
            (Data(),"ef46db3751d8e999"),
            (Data("a".utf8),"d24ec4f1a98c6e5b"),
            (Data("abc".utf8),"44bc2cf5ad770999"),
            (Data("hello".utf8),"26c7827d889f6da3"),
            (Data((0..<256).map { UInt8($0) }),"1facbe8406cd904b")
        ]
        for (input,expected) in vectors {
            let hash=XXH64BE(); hash.update(data:input)
            XCTAssertEqual(hash.finalize().map { String(format:"%02x",$0) }.joined(),expected)
        }
    }
    func testV205XXH64BEStreamingBoundaries() {
        let input=Data((0..<256).map { UInt8($0) })
        for chunkSize in [1,7,31,32,33,64,255,256] {
            let hash=XXH64BE()
            for offset in stride(from:0,to:input.count,by:chunkSize) {
                hash.update(data:input.subdata(in:offset..<min(input.count,offset+chunkSize)))
            }
            XCTAssertEqual(hash.finalize().map { String(format:"%02x",$0) }.joined(),"1facbe8406cd904b")
        }
    }
    func testV205LegacyManifestNotTrusted() throws {
        let source=try file("legacy.txt","same"), destination=try dir("legacy-destination")
        let e=CopyEngine(); e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        let path=destination.appendingPathComponent("NefCopy Reports/.nefcopy_manifest.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any])
        json["version"]=1; json.removeValue(forKey:"algorithm")
        try JSONSerialization.data(withJSONObject:json).write(to:path)
        let result=preflight(e)
        XCTAssertTrue(result.ok)
        XCTAssertFalse(result.messages.contains { $0.contains("cached verified") })
        XCTAssertTrue(result.messages.contains { $0.contains("SKIP — IDENTICAL") })
    }
    func testV205ReportLabelsXXH64BE() throws {
        let source=try file("hash-label.txt","x"), out=root.appendingPathComponent("xxh-report.txt")
        let record=ChecksumRecord(file:"hash-label.txt",source:source.path,destination:"/dest/hash-label.txt",sourceChecksum:"abc",destinationChecksum:"abc",status:"PASS")
        let e=CopyEngine()
        try e.writeTextReport(records:[record],started:Date(),status:"TEST",bytes:1,files:1,verified:true,sources:[source],destinations:[],to:out)
        let html=try String(contentsOf:out)
        XCTAssertTrue(html.contains("Source hash (XXH64BE)"))
        XCTAssertFalse(html.contains("SHA-256"))
    }

    func testV209IncompleteRunIsNotVerified() throws {
        let source=try file("src/a.txt","x"),out=root.appendingPathComponent("incomplete.txt")
        let record=ChecksumRecord(file:"a.txt",source:source.path,destination:"/d/a.txt",sourceChecksum:"a",destinationChecksum:"a",status:"PASS")
        let e=CopyEngine();try e.writeTextReport(records:[record],started:Date(),status:"COMPLETED / VERIFIED",bytes:2,files:2,verified:true,sources:[source],destinations:[],to:out)
        let text=try String(contentsOf:out);XCTAssertTrue(text.contains("Result: NOT FULLY VERIFIED"));XCTAssertTrue(text.contains("Pending/unreported: 1"))
    }
    func testV209MismatchCannotClaimVerifiedInReport() throws {
        let source=try file("src/a.txt","x"),out=root.appendingPathComponent("mismatch.txt")
        let record=ChecksumRecord(file:"a.txt",source:source.path,destination:"/d/a.txt",sourceChecksum:"a",destinationChecksum:"b",status:"PASS")
        let e=CopyEngine();try e.writeTextReport(records:[record],started:Date(),status:"COMPLETED / VERIFIED",bytes:1,files:1,verified:true,sources:[source],destinations:[],to:out)
        XCTAssertTrue(try String(contentsOf:out).contains("Result: NOT FULLY VERIFIED"))
    }
    func testV208RecommendedSettingsKeepFullReadback() {
        let e=CopyEngine();e.verifyEnabled=false;e.verificationSchedule = .pipelined;e.ioBufferSize = .large;e.includeThumbnails=true
        e.useRecommendedSettings()
        XCTAssertTrue(e.verifyEnabled);XCTAssertEqual(e.verificationSchedule,.afterCopy)
        XCTAssertEqual(e.ioBufferSize,.automatic);XCTAssertEqual(e.transferStrategy,.singleReadFanOut);XCTAssertFalse(e.includeThumbnails)
    }
    func testV208CopiedPendingAndTextDiagnostics() throws {
        let a=try binaryFile("v208.bin",megabytes:8),d=try dir("v208-dest")
        let e=CopyEngine();e.useRecommendedSettings();e.testHashDelayPerChunk=0.1;e.setSources([a]);e.addDestinationURL(d);e.start()
        waitUntil { e.state == .verifying && e.pendingVerifyFileCount == 1 }
        XCTAssertEqual(e.copiedFileCount,1);XCTAssertEqual(e.passCount,0);XCTAssertFalse(e.canSafeEject)
        waitUntil { !e.isRunning };XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.pendingVerifyFileCount,0);XCTAssertEqual(e.passCount,1)
        let reports=try FileManager.default.contentsOfDirectory(at:d.appendingPathComponent("NefCopy Reports"),includingPropertiesForKeys:nil)
        let txt=try XCTUnwrap(reports.first{$0.lastPathComponent.hasSuffix("_report.txt")})
        let text=try String(contentsOf:txt);XCTAssertTrue(text.contains("FileHandle read seconds:"));XCTAssertTrue(text.contains("Source hash (XXH64BE)"));XCTAssertTrue(text.contains("PASS"))
    }
    func testV207PipelineCancelThenResume() throws {
        let a=try binaryFile("pipe-cancel-a.bin",megabytes:16), b=try binaryFile("pipe-cancel-b.bin",megabytes:32), d=try dir("pipe-cancel-dest")
        let e=CopyEngine();e.verificationSchedule = .pipelined;e.testCopyDelayPerChunk=0.05;e.setSources([a,b]);e.addDestinationURL(d);e.start()
        waitUntil(5) { e.copiedBytes>16*1024*1024 };e.cancel();waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.cancelled);XCTAssertFalse(e.lastRunWasVerified)
        waitUntil { self.partials(in:d).isEmpty }
        e.testCopyDelayPerChunk=0;e.resumeTransfer();waitUntil { !e.isRunning && e.state != .cancelled }
        XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.passCount,2)
    }
    func testV207PipelineHashesMatchSerial() throws {
        let source=try binaryFile("pipeline-hash.bin",megabytes:9)
        let p=BoundedVerifier()
        try p.submit(source,buffer:4*1024*1024,isCancelled:{false})
        let data=try Data(contentsOf:source); let h=XXH64BE(); h.update(data:data)
        XCTAssertEqual(try p.result(for:source),h.finalize().map{String(format:"%02x",$0)}.joined())
        XCTAssertEqual(p.takeProgress().bytes,Int64(data.count)); XCTAssertEqual(p.takeProgress().bytes,0)
    }
    func testV207PipelineCancellationBeforeSubmit() throws {
        let source=try file("pipeline-cancel.txt","x"), p=BoundedVerifier()
        XCTAssertThrowsError(try p.submit(source,buffer:4096,isCancelled:{true}))
        p.waitForAll()
    }
    func testV207PipelineReadFailurePropagates() throws {
        let p=BoundedVerifier(), missing=root.appendingPathComponent("missing.bin")
        try p.submit(missing,buffer:4096,isCancelled:{false})
        XCTAssertThrowsError(try p.result(for:missing)); p.waitForAll()
    }
    func testV207PipelineCopiesAndVerifiesAllFiles() throws {
        let a=try binaryFile("pipe-a.bin",megabytes:8), b=try binaryFile("pipe-b.bin",megabytes:8), d=try dir("pipe-dest")
        let e=CopyEngine();e.verificationSchedule = .pipelined;e.setSources([a,b]);e.addDestinationURL(d);e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.passCount,2);XCTAssertTrue(e.lastRunWasVerified)
        for source in [a,b] { XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:d.appendingPathComponent(source.lastPathComponent))) }
        XCTAssertTrue(partials(in:d).isEmpty)
    }
    func testV207PipelineCorruptionDoesNotPublish() throws {
        let a=try binaryFile("pipe-corrupt.bin",megabytes:8), d=try dir("pipe-corrupt-dest")
        let e=CopyEngine();e.verificationSchedule = .pipelined;e.testCorruptTempBeforeVerify=true;e.setSources([a]);e.addDestinationURL(d);e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        XCTAssertEqual(e.state,.failed);XCTAssertEqual(e.failCount,1);XCTAssertFalse(e.canSafeEject)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d.appendingPathComponent(a.lastPathComponent).path))
        waitUntil { self.partials(in:d).isEmpty }
        e.retryFailed();waitUntil { !e.isRunning && e.state != .failed };XCTAssertEqual(e.state,.completed)
    }
    func testSpeedfixAllDestinationsSkippedDoNotReadSourceAgain() throws {
        let source=try binaryFile("speedfix.bin",megabytes:16)
        let d1=try dir("speedfix-d1"), d2=try dir("speedfix-d2")
        let e=CopyEngine();e.setSources([source]);e.addDestinationURL(d1);e.addDestinationURL(d2)
        e.start();waitUntil { !e.isRunning && e.state != .idle }
        XCTAssertEqual(e.state,.completed)
        e.testSourceBytesRead=0;e.testManifestLoads=0
        e.start();waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.completed);XCTAssertTrue(e.lastRunWasVerified)
        XCTAssertEqual(e.passCount,2);XCTAssertEqual(e.testSourceBytesRead,0)
        XCTAssertLessThanOrEqual(e.testManifestLoads,6)
        for d in [d1,d2] { XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:d.appendingPathComponent(source.lastPathComponent))) }
    }

    func testSpeedfixMixedSkippedAndNewDestinationStillCopiesAndVerifies() throws {
        let source=try binaryFile("mixed.bin",megabytes:16)
        let d1=try dir("mixed-d1"),d2=try dir("mixed-d2")
        let e=CopyEngine();e.setSources([source]);e.addDestinationURL(d1);e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        e.addDestinationURL(d2);e.testSourceBytesRead=0;e.start();waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.completed);XCTAssertTrue(e.lastRunWasVerified)
        XCTAssertEqual(e.testSourceBytesRead,16*1024*1024);XCTAssertEqual(e.passCount,2)
        for d in [d1,d2] { XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:d.appendingPathComponent(source.lastPathComponent))) }
    }

    func testSpeedfixManifestLoadsStayBoundedForManySkippedFiles() throws {
        let source=try dir("many-speedfix")
        for i in 0..<30 { _=try file("many-speedfix/f\(i).txt","file \(i)") }
        let d=try dir("many-speedfix-dest")
        let e=CopyEngine();e.transferStrategy = .standard;e.setSources([source]);e.addDestinationURL(d)
        e.start();waitUntil { !e.isRunning && e.state != .idle }
        e.testManifestLoads=0;e.start();waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.passCount,30)
        XCTAssertLessThanOrEqual(e.testManifestLoads,2)
    }

    func testSpeedfixChangedDestinationStillBlocksWholeFanout() throws {
        let source=try file("changed.txt","original"),d1=try dir("changed-d1"),d2=try dir("changed-d2")
        let e=CopyEngine();e.setSources([source]);e.addDestinationURL(d1);e.addDestinationURL(d2)
        e.start();waitUntil { !e.isRunning && e.state != .idle }
        try Data("different bytes".utf8).write(to:d2.appendingPathComponent("changed.txt"))
        e.testSourceBytesRead=0;e.start();waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.failed);XCTAssertFalse(e.lastRunWasVerified)
        XCTAssertEqual(try String(contentsOf:d2.appendingPathComponent("changed.txt")),"different bytes")
        XCTAssertEqual(try String(contentsOf:d1.appendingPathComponent("changed.txt")),"original")
    }

    func testIsolatedMultiDestinationReadsSourcePerDestinationAndVerifiesBoth() throws {
        let source=try binaryFile("v210-default-fanout.bin",megabytes:12)
        let d1=try dir("v210-default-fanout-d1"), d2=try dir("v210-default-fanout-d2")
        let e=CopyEngine()
        XCTAssertEqual(e.transferStrategy,.singleReadFanOut)
        e.setSources([source]); e.addDestinationURL(d1); e.addDestinationURL(d2); e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        XCTAssertEqual(e.state,.completed); XCTAssertTrue(e.lastRunWasVerified); XCTAssertEqual(e.passCount,2)
        XCTAssertEqual(e.testSourceBytesRead,24*1024*1024)
        for destination in [d1,d2] {
            XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:destination.appendingPathComponent(source.lastPathComponent)))
        }
        XCTAssertTrue(partials(in:d1).isEmpty); XCTAssertTrue(partials(in:d2).isEmpty)
    }

    func testV207PipelineFanoutVerifiesBothDestinations() throws {
        let a=try binaryFile("pipe-fan.bin",megabytes:8), d=try dir("pipe-fan-d1"), d2=try dir("pipe-fan-d2")
        let e=CopyEngine();e.verificationSchedule = .pipelined;e.transferStrategy = .singleReadFanOut;e.setSources([a]);e.addDestinationURL(d);e.addDestinationURL(d2);e.start()
        waitUntil { !e.isRunning && e.state != .idle };XCTAssertEqual(e.state,.completed);XCTAssertEqual(e.passCount,2)
        for destination in [d,d2] { XCTAssertEqual(try Data(contentsOf:a),try Data(contentsOf:destination.appendingPathComponent(a.lastPathComponent))) }
    }
    func testV206PreflightCancelDrainsBeforeNewStart() throws {
        let source=try binaryFile("preflight-cancel.bin",megabytes:32), destination=try dir("preflight-cancel-dest")
        try FileManager.default.copyItem(at:source,to:destination.appendingPathComponent(source.lastPathComponent))
        let e=CopyEngine(); e.testHashDelayPerChunk=0.05; e.setSources([source]); e.addDestinationURL(destination)
        var result:PreflightResult?
        e.runPreflight { result=$0 }
        waitUntil(5) { e.phaseName == "Checking existing file" && e.phaseProgress>0 }
        XCTAssertTrue(e.isPreflighting)
        e.cancelPreflight(); e.start()
        XCTAssertEqual(e.state,.idle)
        waitUntil(5) { !e.isPreflighting }
        XCTAssertFalse(try XCTUnwrap(result).ok)
        e.testHashDelayPerChunk=0; e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        XCTAssertEqual(e.state,.completed)
    }
    func testV206CopyAllKeepsFinalNamesUnpublishedUntilVerified() throws {
        let source=try dir("deferred-source")
        _=try binaryFile("deferred-source/a.bin",megabytes:16)
        _=try binaryFile("deferred-source/b.bin",megabytes:16)
        let destination=try dir("deferred-dest")
        let e=CopyEngine(); e.verificationSchedule = .afterCopy; e.testHashDelayPerChunk=0.1
        e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil(5) { e.phaseName == "Verifying destination" && e.phaseProgress>0 }
        XCTAssertEqual(e.copiedBytes,32*1024*1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathComponent("deferred-source/b.bin").path))
        XCTAssertFalse(e.canSafeEject)
        waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.completed); XCTAssertEqual(e.passCount,2)
        XCTAssertTrue(partials(in:destination).isEmpty)
    }
    func testV206DeferredCancelRemovesAllUnverifiedFiles() throws {
        let source=try dir("deferred-cancel-source")
        _=try binaryFile("deferred-cancel-source/a.bin",megabytes:16)
        _=try binaryFile("deferred-cancel-source/b.bin",megabytes:16)
        let destination=try dir("deferred-cancel-dest")
        let e=CopyEngine(); e.verificationSchedule = .afterCopy; e.testHashDelayPerChunk=0.1
        e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil(5) { e.phaseName == "Verifying destination" && e.phaseProgress>0 }
        e.cancel(); waitUntil { !e.isRunning }
        XCTAssertEqual(e.state,.cancelled); XCTAssertFalse(e.lastRunWasVerified)
        waitUntil { self.partials(in:destination).isEmpty }
        XCTAssertTrue(partials(in:destination).isEmpty)
        e.testHashDelayPerChunk=0; e.resumeTransfer(); waitUntil { !e.isRunning && e.state != .cancelled }
        XCTAssertEqual(e.state,.completed)
    }
    func testV206CopyPhaseHasConsistentNameAndSize() throws {
        let source=try binaryFile("phase-size.bin",megabytes:32), destination=try dir("phase-size-dest")
        let e=CopyEngine(); e.testCopyDelayPerChunk=0.05; e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil(5) { e.phaseName == "Copying" && e.phaseBytes>0 }
        XCTAssertEqual(e.phaseTotalBytes,32*1024*1024)
        XCTAssertGreaterThan(e.phaseProgress,0); XCTAssertLessThan(e.phaseProgress,1)
        e.cancel(); waitUntil { !e.isRunning }
    }
    func testV206BufferChoicesProduceSameVerifiedBytes() throws {
        let source=try binaryFile("buffers.bin",megabytes:17)
        for buffer in IOBufferSize.allCases {
            let destination=try dir("buffer-\(buffer.rawValue)")
            let e=CopyEngine(); e.ioBufferSize=buffer; e.setSources([source]); e.addDestinationURL(destination); e.start()
            waitUntil { !e.isRunning && e.state != .idle }
            XCTAssertEqual(e.state,.completed)
            XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:destination.appendingPathComponent(source.lastPathComponent)))
        }
    }
    func testV206PerFileScheduleStillVerifiesBeforeNextFile() throws {
        let source=try dir("per-file-source")
        _=try binaryFile("per-file-source/a.bin",megabytes:16)
        _=try binaryFile("per-file-source/b.bin",megabytes:16)
        let destination=try dir("per-file-dest")
        let e=CopyEngine(); e.verificationSchedule = .perFile; e.testHashDelayPerChunk=0.1
        e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil(5) { e.phaseName == "Verifying destination" && e.phaseProgress>0 }
        XCTAssertEqual(e.copiedBytes,16*1024*1024)
        waitUntil { !e.isRunning }; XCTAssertEqual(e.state,.completed)
    }

    func testV206DeferredCorruptionFailsWithoutPublishingTarget() throws {
        let source=try binaryFile("corrupt.bin",megabytes:2), destination=try dir("corrupt-dest")
        let e=CopyEngine(); e.verificationSchedule = .afterCopy; e.testCorruptTempBeforeVerify=true
        e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        XCTAssertEqual(e.state,.failed); XCTAssertEqual(e.failCount,1)
        XCTAssertFalse(e.canSafeEject)
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathComponent("corrupt.bin").path))
        waitUntil { self.partials(in:destination).isEmpty }
        XCTAssertTrue(partials(in:destination).isEmpty)
        e.retryFailed(); waitUntil { !e.isRunning && e.state != .failed }
        XCTAssertEqual(e.state,.completed)
    }
    func testV206ThumbnailsOffStillCreatesChecksumReports() throws {
        let source=try file("plain.txt","plain"), destination=try dir("thumb-off-dest")
        let e=CopyEngine(); XCTAssertFalse(e.includeThumbnails)
        e.setSources([source]); e.addDestinationURL(destination); e.start()
        waitUntil { !e.isRunning && e.state != .idle }
        XCTAssertEqual(e.state,.completed)
        let report=try XCTUnwrap(e.lastReportURL)
        let html=try String(contentsOf:report)
        XCTAssertTrue(html.contains("Source hash (XXH64BE)"))
        XCTAssertFalse(html.contains("<html"))
    }

}
