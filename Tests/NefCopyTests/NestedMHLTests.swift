import XCTest
@testable import NefCopy
final class NestedMHLTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("NefNested-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func file(_ path:String,_ value:String="data")throws->ChecksumRecord {
        let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(value.utf8).write(to:url)
        let(hash,n,_)=try ASCMHL.hashFile(url);return ChecksumRecord(file:path,source:url.path,destination:url.path,sourceChecksum:hash,destinationChecksum:hash,status:"PASS",size:n)
    }
    private func nested()throws {
        let a=try file("การ์ด/scene/ไทย.bin");_=try ASCMHL.appendVerified(root:root.appendingPathComponent("การ์ด/scene"),records:[a])
        let b=try file("การ์ด/b.bin");_=try ASCMHL.appendVerified(root:root.appendingPathComponent("การ์ด"),records:[b])
        let c=try file("top.bin");_=try ASCMHL.appendVerified(root:root,records:[c])
    }
    func testTwoNestedLevelsUseNearestOwnerAndReferences()throws {
        try nested();let history=try ASCMHL.load(root:root)
        XCTAssertEqual(history.files.count,3);XCTAssertEqual(history.references.count,1);XCTAssertEqual(history.nestedFingerprints.count,2)
        let doc=try String(contentsOf:root.appendingPathComponent("ascmhl/"+history.generations.last!.path))
        XCTAssertTrue(doc.contains("<roothash>"));XCTAssertTrue(doc.contains("<references>"));XCTAssertFalse(doc.contains(">การ์ด/b.bin<"))
        XCTAssertEqual(try ASCMHL.verify(root:root).files,3)
    }
    func testParentVerificationPropagatesNewChildGenerations()throws {
        try nested();let before=try ASCMHL.load(root:root.appendingPathComponent("การ์ด/scene")).generations.count
        _=try ASCMHL.verifyAndRecord(root:root)
        XCTAssertEqual(try ASCMHL.load(root:root.appendingPathComponent("การ์ด/scene")).generations.count,before+1)
        XCTAssertEqual(try ASCMHL.verify(root:root).files,3)
    }
    func testEmptyDirectoryAddedIsDetected()throws {
        let a=try file("a");_=try ASCMHL.appendVerified(root:root,records:[a])
        try FileManager.default.createDirectory(at:root.appendingPathComponent("new-empty"),withIntermediateDirectories:false)
        XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testEmptyDirectoryRemovedIsDetected()throws {
        let a=try file("a");let empty=root.appendingPathComponent("empty");try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:false)
        _=try ASCMHL.appendVerified(root:root,records:[a]);try FileManager.default.removeItem(at:empty)
        XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testNewUnlistedFileIsDetected()throws {let a=try file("a");_=try ASCMHL.appendVerified(root:root,records:[a]);_=try file("new");XCTAssertThrowsError(try ASCMHL.verify(root:root))}
    func testModifiedChildManifestIsDetectedThroughParent()throws {
        try nested();let child=root.appendingPathComponent("การ์ด/scene"),history=try ASCMHL.load(root:child),path=child.appendingPathComponent("ascmhl/"+history.generations.first!.path)
        try Data("corrupt".utf8).write(to:path);XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testMissingChildChainIsDetected()throws {try nested();try FileManager.default.removeItem(at:root.appendingPathComponent("การ์ด/ascmhl/ascmhl_chain.xml"));XCTAssertThrowsError(try ASCMHL.verify(root:root))}
    func testNestedSymlinkIsNotFollowed()throws {
        try nested();let card=root.appendingPathComponent("การ์ด"),saved=root.appendingPathComponent("owned-saved");try FileManager.default.moveItem(at:card,to:saved);try FileManager.default.createSymbolicLink(at:card,withDestinationURL:saved)
        XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testLegacyFileOnlyHistoryStillLoads()throws {
        let a=try file("a");_=try ASCMHL.appendVerified(root:root,records:[a]);XCTAssertEqual(try ASCMHL.verify(root:root).files,1)
    }
    private func transfer(_ strategy:TransferStrategy)throws {
        let a=try file("source/card/a"),source=root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source.appendingPathComponent("card/empty-dir"),withIntermediateDirectories:false)
        _=try ASCMHL.appendVerified(root:source.appendingPathComponent("card"),records:[a])
        let dests=[root.appendingPathComponent("a-dest"),root.appendingPathComponent("b-dest")]
        for d in dests {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)}
        let e=CopyEngine();e.sourceURLs=[source];e.destinations=dests.map{Destination(url:$0)};e.ascMHLEnabled=true;e.transferStrategy=strategy;e.cascadePrimaryDestination=dests[0]
        e.start();let end=Date().addingTimeInterval(25);while e.isRunning && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertTrue(e.lastRunWasVerified,e.errorMessage ?? "Timed out")
        for d in dests {XCTAssertEqual(try ASCMHL.verify(root:d).files,1);XCTAssertTrue(FileManager.default.fileExists(atPath:d.appendingPathComponent("source/card/empty-dir").path))}
    }
    func testMixedExistingAndNewDestinationPreservesExtendedHistory()throws {
        let entry=try file("source/card/a"),source=root.appendingPathComponent("source")
        _=try ASCMHL.appendVerified(root:source.appendingPathComponent("card"),records:[entry])
        let old=root.appendingPathComponent("old"),fresh=root.appendingPathComponent("fresh")
        for d in [old,fresh] {try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)}
        let e=CopyEngine();e.sourceURLs=[source];e.destinations=[Destination(url:old)];e.ascMHLEnabled=true
        func finish(){let end=Date().addingTimeInterval(25);while e.isRunning && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))};XCTAssertTrue(e.lastRunWasVerified,e.errorMessage ?? "Failed")}
        e.start();finish();let prior=try ASCMHL.load(root:old).generations[0]
        e.destinations=[old,fresh].map{Destination(url:$0)}
        var result:PreflightResult?;e.runPreflight{result=$0}
        let end=Date().addingTimeInterval(25);while result==nil && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertTrue(result?.ok==true,result?.messages.joined(separator:"\n") ?? "Timeout")
        e.start();finish()
        XCTAssertEqual(try ASCMHL.load(root:old).generations[0].c4,prior.c4)
        for d in [old,fresh] {XCTAssertEqual(try ASCMHL.verify(root:d).files,1)}
    }
    func testCopyNestedSourceHistoryMultiDrive()throws {try transfer(.singleReadFanOut)}
    func testCopyNestedSourceHistoryCascading()throws {try transfer(.cascading)}
}
