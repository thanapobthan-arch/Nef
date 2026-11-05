import XCTest
import CryptoKit
@testable import NefCopy
final class RenameMHLTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("NefRename-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func record(_ path:String,_ content:String="payload")throws->ChecksumRecord {
        let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(content.utf8).write(to:url)
        let(hash,n,_)=try ASCMHL.hashFile(url);return ChecksumRecord(file:path,source:url.path,destination:url.path,sourceChecksum:hash,destinationChecksum:hash,status:"PASS",size:n)
    }
    private func move(_ old:String,_ new:String)throws {
        let target=root.appendingPathComponent(new);try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.moveItem(at:root.appendingPathComponent(old),to:target)
    }
    private func seed()throws {let a=try record("folder/old.txt"),b=try record("other.txt","other");_=try ASCMHL.appendVerified(root:root,records:[a,b])}
    func testRenamePreservesOldManifestAndChecksums()throws {
        try seed();let history=try ASCMHL.load(root:root),original=root.appendingPathComponent("ascmhl/"+history.generations[0].path),bytes=try Data(contentsOf:original)
        try move("folder/old.txt","folder/ชื่อใหม่ & <x>.txt")
        XCTAssertThrowsError(try ASCMHL.verify(root:root))
        _=try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"folder/ชื่อใหม่ & <x>.txt")
        XCTAssertEqual(try Data(contentsOf:original),bytes);let updated=try ASCMHL.load(root:root)
        XCTAssertNil(updated.files["folder/old.txt"]);XCTAssertEqual(updated.files["folder/ชื่อใหม่ & <x>.txt"]?.hash,history.files["folder/old.txt"]?.hash)
        XCTAssertTrue(try String(contentsOf:root.appendingPathComponent("ascmhl/"+updated.generations.last!.path)).contains("<previousPath>folder/old.txt</previousPath>"))
        XCTAssertEqual(try ASCMHL.verify(root:root).files,2)
    }
    func testMoveAndRemoveOldFolderRecalculatesDirectorySnapshot()throws {
        try seed();try move("folder/old.txt","new/place/file.txt");try FileManager.default.removeItem(at:root.appendingPathComponent("folder"))
        _=try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"new/place/file.txt")
        XCTAssertEqual(try ASCMHL.verify(root:root).files,2)
    }
    func testMoveSameFilenameWithRemovedOldDirectory()throws {
        try seed();try move("folder/old.txt","new/old.txt");try FileManager.default.removeItem(at:root.appendingPathComponent("folder"))
        _=try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"new/old.txt")
        XCTAssertEqual(try ASCMHL.verify(root:root).files,2)
    }
    func testRepeatedRenameAndNoPreviousPathOnLaterVerification()throws {
        try seed();try move("folder/old.txt","folder/B.txt");_=try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"folder/B.txt")
        try move("folder/B.txt","folder/C.txt");_=try ASCMHL.recordRename(root:root,previousPath:"folder/B.txt",newPath:"folder/C.txt")
        _=try ASCMHL.verifyAndRecord(root:root);let h=try ASCMHL.load(root:root)
        XCTAssertFalse(try String(contentsOf:root.appendingPathComponent("ascmhl/"+h.generations.last!.path)).contains("previousPath"))
        XCTAssertEqual(try ASCMHL.verify(root:root).files,2)
    }
    func testOfficialOriginalActionWithPreviousPathStillChecksOriginalHash()throws {
        try seed();try move("folder/old.txt","new.txt");_=try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"new.txt")
        let generation=try ASCMHL.load(root:root).generations.last!,manifest=root.appendingPathComponent("ascmhl/"+generation.path),chain=root.appendingPathComponent("ascmhl/ascmhl_chain.xml")
        let data=Data(try String(contentsOf:manifest).replacingOccurrences(of:"action=\"verified\"",with:"action=\"original\"").utf8)
        try data.write(to:manifest)
        try String(contentsOf:chain).replacingOccurrences(of:generation.c4,with:ASCMHL.c4(data)).write(to:chain,atomically:true,encoding:.utf8)
        XCTAssertEqual(try ASCMHL.verify(root:root).files,2)
    }
    func testChangedRenamedContentCannotBeRehabilitated()throws {
        try seed();let chain=root.appendingPathComponent("ascmhl/ascmhl_chain.xml"),before=try Data(contentsOf:chain)
        try move("folder/old.txt","new.txt");try Data("changed".utf8).write(to:root.appendingPathComponent("new.txt"))
        XCTAssertThrowsError(try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"new.txt"));XCTAssertEqual(try Data(contentsOf:chain),before)
    }
    func testCaseOnlyFilenameRename()throws {
        try seed();try move("folder/old.txt","folder/OLD.txt")
        _=try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"folder/OLD.txt")
        XCTAssertEqual(try ASCMHL.verify(root:root).files,2)
    }
    func testUnrelatedDirectoryRemovalCannotBeHiddenByRename()throws {
        let extra=root.appendingPathComponent("unrelated-empty");try FileManager.default.createDirectory(at:extra,withIntermediateDirectories:false)
        try seed();try move("folder/old.txt","folder/new.txt");try FileManager.default.removeItem(at:extra)
        XCTAssertThrowsError(try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"folder/new.txt"))
    }
    func testCopiedFileIsNotMistakenForRename()throws {
        try seed();try FileManager.default.copyItem(at:root.appendingPathComponent("folder/old.txt"),to:root.appendingPathComponent("new.txt"))
        XCTAssertThrowsError(try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"new.txt"))
    }
    func testCollisionWithRecordedFileIsRejected()throws {
        try seed();try FileManager.default.removeItem(at:root.appendingPathComponent("folder/old.txt"))
        XCTAssertThrowsError(try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"other.txt"))
    }
    func testAnotherChangedFileBlocksRecording()throws {
        try seed();try move("folder/old.txt","new.txt");try Data("damage".utf8).write(to:root.appendingPathComponent("other.txt"))
        XCTAssertThrowsError(try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"new.txt"))
    }
    func testPathTraversalAndSymlinkAreRejected()throws {
        try seed();try move("folder/old.txt","new.txt")
        XCTAssertThrowsError(try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"../new.txt"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:root.appendingPathComponent("new.txt"))
        XCTAssertThrowsError(try ASCMHL.recordRename(root:root,previousPath:"folder/old.txt",newPath:"link"))
    }
    func testNestedHistoryRenamePropagatesParentReference()throws {
        let a=try record("card/scene/old.txt");_=try ASCMHL.appendVerified(root:root.appendingPathComponent("card/scene"),records:[a])
        let b=try record("top.txt");_=try ASCMHL.appendVerified(root:root,records:[b])
        try move("card/scene/old.txt","card/scene/moved/new.txt")
        _=try ASCMHL.recordRename(root:root,previousPath:"card/scene/old.txt",newPath:"card/scene/moved/new.txt")
        XCTAssertEqual(try ASCMHL.verify(root:root).files,2)
    }
    func testCrossHistoryBoundaryMoveIsRejected()throws {
        let a=try record("card/old.txt");_=try ASCMHL.appendVerified(root:root.appendingPathComponent("card"),records:[a]);let b=try record("top.txt");_=try ASCMHL.appendVerified(root:root,records:[b])
        try move("card/old.txt","new.txt");XCTAssertThrowsError(try ASCMHL.recordRename(root:root,previousPath:"card/old.txt",newPath:"new.txt"))
    }
    func testIdenticalContentUsesExplicitOldIdentity()throws {
        let a=try record("a"),b=try record("b");_=try ASCMHL.appendVerified(root:root,records:[a,b]);try move("a","new")
        _=try ASCMHL.recordRename(root:root,previousPath:"a",newPath:"new");XCTAssertEqual(try ASCMHL.verify(root:root).files,2)
    }
}
