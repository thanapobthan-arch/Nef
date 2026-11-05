import XCTest
import CryptoKit
@testable import NefCopy

final class ASCMHLTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopyASCMHL-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func file(_ name:String,_ data:Data)throws->URL {let url=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:url);return url}
    private func record(_ file:URL)throws->ChecksumRecord {let(h,n,_)=try ASCMHL.hashFile(file);return ChecksumRecord(file:file.lastPathComponent,source:file.path,destination:file.path,sourceChecksum:h,destinationChecksum:h,status:"PASS",size:n)}
    private func seed()throws->URL {
        let a=try file("การ์ด/ซ้อน/clip&<\".bin",Data([0,1,2,3,255])),b=try file("empty",Data())
        return try ASCMHL.appendVerified(root:root,records:[record(a),record(b)])
    }
    private func editManifest(_ body:(String)->String)throws {
        let chain=root.appendingPathComponent("ascmhl/ascmhl_chain.xml"),old=try ASCMHL.load(root:root).generations[0]
        let manifest=root.appendingPathComponent("ascmhl/"+old.path)
        let data=Data(body(try String(contentsOf:manifest)).utf8);try data.write(to:manifest)
        let text=try String(contentsOf:chain).replacingOccurrences(of:old.c4,with:ASCMHL.c4(data));try text.write(to:chain,atomically:true,encoding:.utf8)
    }
    private func wait(_ condition:()->Bool) {let end=Date().addingTimeInterval(25);while !condition() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))};XCTAssertTrue(condition(),"Timed out")}
    func testC4AgainstOfficialReferenceVectors() {
        XCTAssertEqual(ASCMHL.c4(Data()),"c459dsjfscH38cYeXXYogktxf4Cd9ibshE3BHUo6a58hBXmRQdZrAkZzsWcbWtDg5oQstpDuni4Hirj75GEmTc1sFT")
        XCTAssertEqual(ASCMHL.c4(Data("abc".utf8)),"c45S4rnaTNWonxss1u8LzsaJdEph1AJhWUF4sh2waXKMsutyfAxg4ybUeuXVWS9HdNcEypmeXn8FZGonD4w1rj9DZp")
    }
    func testUnicodeEscapingEmptyFileAndReadback()throws {
        let manifest=try seed();let result=try ASCMHL.verify(root:root)
        XCTAssertEqual(result.files,2);XCTAssertEqual(result.bytes,5);XCTAssertEqual(result.generations,1)
        XCTAssertTrue(try String(contentsOf:manifest).contains("&amp;"))
        XCTAssertTrue(try String(contentsOf:manifest).contains("action=\"original\""))
    }
    func testAppendPreservesFirstGenerationAndCumulativeFiles()throws {
        let first=try seed(),bytes=try Data(contentsOf:first),new=try file("new.bin",Data("new".utf8))
        let second=try ASCMHL.appendVerified(root:root,records:[record(new)])
        XCTAssertEqual(try Data(contentsOf:first),bytes);XCTAssertNotEqual(first,second)
        let result=try ASCMHL.verify(root:root);XCTAssertEqual(result.generations,2);XCTAssertEqual(result.files,3)
        XCTAssertTrue(try String(contentsOf:second).contains("action=\"verified\""))
    }
    func testSameSizeMtimeTamperingFails()throws {
        _=try seed();let url=root.appendingPathComponent("การ์ด/ซ้อน/clip&<\".bin")
        let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
        try Data([9,9,9,9,9]).write(to:url)
        try FileManager.default.setAttributes([.modificationDate:attrs[.modificationDate]!],ofItemAtPath:url.path)
        XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testOptionalSizeFromReferenceImplementationIsAccepted()throws {
        _=try seed();try editManifest{$0.replacingOccurrences(of:" size=\"0\"",with:"")}
        XCTAssertEqual(try ASCMHL.verify(root:root).files,2)
    }
    func testVerificationAppendsVerifiedGenerationWithConformingName()throws {
        _=try seed();let result=try ASCMHL.verifyAndRecord(root:root)
        XCTAssertEqual(result.generations,2)
        let history=try ASCMHL.load(root:root),name=history.generations.last!.path
        XCTAssertNotNil(name.range(of:"^0002_.*_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}Z\\.mhl$",options:.regularExpression))
        XCTAssertTrue(try String(contentsOf:root.appendingPathComponent("ascmhl/"+name)).contains("action=\"verified\""))
    }
    func testMissingMediaFails()throws {_=try seed();try FileManager.default.removeItem(at:root.appendingPathComponent("empty"));XCTAssertThrowsError(try ASCMHL.verify(root:root))}
    func testModifiedManifestFailsC4()throws {let url=try seed();try Data("tampered".utf8).write(to:url);XCTAssertThrowsError(try ASCMHL.verify(root:root))}
    func testBrokenChainFails()throws {_=try seed();try Data("broken".utf8).write(to:root.appendingPathComponent("ascmhl/ascmhl_chain.xml"));XCTAssertThrowsError(try ASCMHL.verify(root:root))}
    func testTraversalRejectedEvenWithRecomputedManifestC4()throws {_=try seed();try editManifest{$0.replacingOccurrences(of:">empty<",with:">../outside<")};XCTAssertThrowsError(try ASCMHL.verify(root:root))}
    func testUnsupportedAlgorithmRejectedEvenWithValidC4()throws {_=try seed();try editManifest{$0.replacingOccurrences(of:"xxh64",with:"sha1")};XCTAssertThrowsError(try ASCMHL.verify(root:root))}
    func testDTDRejectedEvenWithValidC4()throws {_=try seed();try editManifest{$0.replacingOccurrences(of:"<hashlist",with:"<!DOCTYPE hashlist [<!ENTITY leak SYSTEM 'file:///etc/passwd'>]><hashlist")};XCTAssertThrowsError(try ASCMHL.verify(root:root))}
    func testSymlinkedMediaRejected()throws {_=try seed();let other=try file("owned-other",Data());let target=root.appendingPathComponent("empty");try FileManager.default.removeItem(at:target);try FileManager.default.createSymbolicLink(at:target,withDestinationURL:other);XCTAssertThrowsError(try ASCMHL.verify(root:root))}
    func testUnchainedManifestIsNotOverwritten()throws {let first=try seed();let chain=root.appendingPathComponent("ascmhl/ascmhl_chain.xml");try FileManager.default.removeItem(at:chain);let data=try Data(contentsOf:first);let url=try file("new",Data());XCTAssertThrowsError(try ASCMHL.appendVerified(root:root,records:[record(url)]));XCTAssertEqual(try Data(contentsOf:first),data)}
    func testLockedHistoryIsNotModified()throws {_=try seed();let chain=root.appendingPathComponent("ascmhl/ascmhl_chain.xml"),before=try Data(contentsOf:chain);_=try file("ascmhl/.nefcopy-ascmhl.lock",Data());let url=try file("new",Data());XCTAssertThrowsError(try ASCMHL.appendVerified(root:root,records:[record(url)]));XCTAssertEqual(try Data(contentsOf:chain),before)}
    func testCancelDoesNotCommitHistory()throws {let url=try file("test",Data([1]));XCTAssertThrowsError(try ASCMHL.appendVerified(root:root,records:[record(url)],checkpoint:{throw CopyError.cancelled}));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("ascmhl/ascmhl_chain.xml").path))}
    func testFailedCopyCannotBeRecorded()throws {let url=try file("test",Data([1]));var r=try record(url);r=ChecksumRecord(file:r.file,source:r.source,destination:r.destination,sourceChecksum:r.sourceChecksum,destinationChecksum:r.destinationChecksum,status:"FAIL");XCTAssertThrowsError(try ASCMHL.appendVerified(root:root,records:[r]))}
    func testCannotReplaceHistoricalChecksumWithChangedFile()throws {_=try seed();let url=root.appendingPathComponent("empty");try Data([1]).write(to:url);XCTAssertThrowsError(try ASCMHL.appendVerified(root:root,records:[record(url)]))}
    private func transfer(_ strategy:TransferStrategy)throws {
        let a=try file("card/ไทย.txt",Data("MHL test ภาษาไทย".utf8)),b=try file("card/empty",Data())
        let dests=[root.appendingPathComponent("dest-a"),root.appendingPathComponent("dest-b")]
        for d in dests {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)}
        let e=CopyEngine();e.sourceURLs=[a.deletingLastPathComponent()];e.destinations=dests.map{Destination(url:$0)};e.transferStrategy=strategy;e.cascadePrimaryDestination=dests[0];e.independentSourceVerification=true;e.ascMHLEnabled=true
        e.start();wait{!e.isRunning};XCTAssertTrue(e.lastRunWasVerified,e.errorMessage ?? "");XCTAssertEqual(e.failCount,0)
        for d in dests {XCTAssertEqual(try ASCMHL.verify(root:d).files,2);for f in [a,b] {XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:f)),SHA256.hash(data:try Data(contentsOf:d.appendingPathComponent("card/"+f.lastPathComponent))))}}
    }
    func testMultiDriveCreatesVerifiedHistoryForBothDestinations()throws {try transfer(.singleReadFanOut)}
    func testStandardCreatesVerifiedHistory()throws {try transfer(.standard)}
    func testCascadingCreatesVerifiedHistory()throws {try transfer(.cascading)}
    func testExportFailureDoesNotProduceVerifiedJob()throws {
        let source=try file("source",Data([1,2])),dest=root.appendingPathComponent("dest");_=try file("dest/ascmhl",Data([0]))
        let e=CopyEngine();e.sourceURLs=[source];e.destinations=[Destination(url:dest)];e.ascMHLEnabled=true;e.start();wait{!e.isRunning}
        XCTAssertFalse(e.lastRunWasVerified);XCTAssertEqual(e.state,.failed)
    }
    func testQueueReopensWithASCMHLAndCreatesHistory()throws {
        let source=try file("card/media",Data([1,2,3])),dest=root.appendingPathComponent("queued-dest")
        try FileManager.default.createDirectory(at:dest,withIntermediateDirectories:true)
        let spec=TransferJobSettings(sources:[source.deletingLastPathComponent()],destinations:[dest],independentSourceVerification:true,ascMHLEnabled:true)
        let store=root.appendingPathComponent("queue.json")
        var first:TransferQueue?=TransferQueue(storageURL:store,startPaused:true);XCTAssertNotNil(first!.enqueue(spec));first=nil
        let q=TransferQueue(storageURL:store);XCTAssertEqual(q.jobs[0].settings.ascMHLEnabled,true)
        q.resumeQueue();wait{!q.isBusy && !q.hasPending};XCTAssertEqual(q.jobs[0].state,.verified)
        XCTAssertEqual(try ASCMHL.verify(root:dest).files,1)
    }
    func testDisabledModeDoesNotCreateASCMHL()throws {
        let source=try file("source",Data([1])),dest=root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at:dest,withIntermediateDirectories:true)
        let e=CopyEngine();e.sourceURLs=[source];e.destinations=[Destination(url:dest)];e.start();wait{!e.isRunning}
        XCTAssertTrue(e.lastRunWasVerified);XCTAssertFalse(FileManager.default.fileExists(atPath:dest.appendingPathComponent("ascmhl").path))
    }
    func testStandaloneVerifierShowsSuccessAndFailure()throws {
        _=try seed();let verifier=ASCMHLVerifier();verifier.start(root:root);wait{!verifier.isRunning}
        XCTAssertTrue(verifier.status.hasPrefix("ASC MHL verified:"))
        try Data([1]).write(to:root.appendingPathComponent("empty"));verifier.start(root:root);wait{!verifier.isRunning}
        XCTAssertTrue(verifier.status.contains("did not pass"))
    }
    func testASCMHLRequiresChecksumVerification()throws {
        let source=try file("source",Data([1])),dest=root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at:dest,withIntermediateDirectories:true)
        let e=CopyEngine();e.sourceURLs=[source];e.destinations=[Destination(url:dest)];e.ascMHLEnabled=true;e.verifyEnabled=false
        var result:PreflightResult?;e.runPreflight{result=$0};wait{result != nil};XCTAssertFalse(result!.ok)
    }
    func testOldSettingsDefaultToDisabledAndNewSettingsRoundTrip()throws {
        let e=CopyEngine();e.ascMHLEnabled=true
        let data=try JSONEncoder().encode(TransferJobSettings(engine:e));XCTAssertEqual(try JSONDecoder().decode(TransferJobSettings.self,from:data).ascMHLEnabled,true)
        var value=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);value.removeValue(forKey:"ascMHLEnabled")
        XCTAssertFalse(try JSONDecoder().decode(TransferJobSettings.self,from:JSONSerialization.data(withJSONObject:value)).ascMHLEnabled ?? false)
    }
}
