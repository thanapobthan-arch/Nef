import XCTest
import CryptoKit
@testable import NefCopy
final class TransferReceiptTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("NefTransfer-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try? FileManager.default.removeItem(at:root)}
    private func file(_ path:String,_ text:String)throws->ChecksumRecord {
        let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:url)
        let(hash,size,_)=try ASCMHL.hashFile(url);return ChecksumRecord(file:path,source:url.path,destination:url.path,sourceChecksum:hash,destinationChecksum:hash,status:"PASS",size:size)
    }
    private func seed(emptySource:Bool=false,deep:Bool=false,third:Bool=false)throws->(String,String) {
        let owner=deep ? "A/scene":"A",old=owner+"/ไทย & [x]*.bin",new="B/arrived.bin"
        let a=try file(old,"unchanged payload"),b=try file("B/stay.txt","B")
        var records=[a];if !emptySource {records.append(try file(owner+"/stay.txt","A"))}
        _=try ASCMHL.appendVerified(root:root.appendingPathComponent(owner),records:records)
        _=try ASCMHL.appendVerified(root:root.appendingPathComponent("B"),records:[b])
        if third {let c=try file("C/stay.txt","C");_=try ASCMHL.appendVerified(root:root.appendingPathComponent("C"),records:[c])}
        let top=try file("top.txt","top");_=try ASCMHL.appendVerified(root:root,records:[top])
        try FileManager.default.moveItem(at:root.appendingPathComponent(old),to:root.appendingPathComponent(new));return(old,new)
    }
    func testCrossHistoryMoveChecksBothPeersAndParent()throws {
        let(old,new)=try seed();let before=try Data(contentsOf:root.appendingPathComponent(new)),original=try ASCMHL.load(root:root.appendingPathComponent("A")).generations[0]
        let result=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        XCTAssertEqual(result.pendingTransfers,0);XCTAssertEqual(result.transferLinks,1);XCTAssertEqual(result.transferredOut,1);XCTAssertEqual(result.files,4)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(new)),before)
        XCTAssertEqual(try ASCMHL.load(root:root.appendingPathComponent("A")).generations[0].c4,original.c4)
        let a=try ASCMHL.verify(root:root.appendingPathComponent("A")),b=try ASCMHL.verify(root:root.appendingPathComponent("B"))
        XCTAssertEqual(a.files,1);XCTAssertEqual(a.transferredOut,1);XCTAssertEqual(a.pendingTransfers,1)
        XCTAssertEqual(b.files,2);XCTAssertEqual(b.pendingTransfers,1)
        XCTAssertEqual(try ASCMHL.verify(root:root).pendingTransfers,0)
    }
    func testEmptySourceStillShowsMovedOutRatherThanFalseFullPass()throws {
        let(old,new)=try seed(emptySource:true);_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        let a=try ASCMHL.verifyAndRecord(root:root.appendingPathComponent("A"));XCTAssertEqual(a.files,0);XCTAssertEqual(a.pendingTransfers,1);XCTAssertEqual(a.transferredOut,1)
    }
    func testDeeperNestedOwners()throws {
        let(old,new)=try seed(deep:true);_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        XCTAssertEqual(try ASCMHL.verify(root:root).transferLinks,1)
    }
    func testDestinationCorruptionAfterTransferFailsParentAudit()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        try Data("corrupt".utf8).write(to:root.appendingPathComponent(new));XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testWrongDestinationHashDoesNotChangeSourceChain()throws {
        let(old,new)=try seed();let chain=root.appendingPathComponent("A/ascmhl/ascmhl_chain.xml"),before=try Data(contentsOf:chain)
        try Data("bad".utf8).write(to:root.appendingPathComponent(new));XCTAssertThrowsError(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new));XCTAssertEqual(try Data(contentsOf:chain),before)
    }
    func testOldPathReappearingIsNotSilentlyIgnored()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        try Data("reappeared".utf8).write(to:root.appendingPathComponent(old));XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testNormalVerificationPreservesTransferNotesAndIgnores()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        _=try ASCMHL.verifyAndRecord(root:root)
        XCTAssertEqual(try ASCMHL.verify(root:root).transferLinks,1)
    }
    func testWithinOwnerRenameAfterTransferKeepsReceiptLink()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        try FileManager.default.moveItem(at:root.appendingPathComponent(new),to:root.appendingPathComponent("B/renamed.bin"))
        _=try ASCMHL.recordRename(root:root,previousPath:new,newPath:"B/renamed.bin")
        XCTAssertEqual(try ASCMHL.verify(root:root).transferLinks,1)
    }
    func testRetryAfterSourceRetiredCommitAndNoParentLink()throws {
        let(old,new)=try seed();var interrupted=false
        XCTAssertThrowsError(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new,checkpoint:{
            if !interrupted,let source=try? ASCMHL.load(root:self.root.appendingPathComponent("A")),!source.retired.isEmpty {interrupted=true;throw CopyError.cancelled}
        }))
        XCTAssertTrue(interrupted);XCTAssertThrowsError(try ASCMHL.verify(root:root))
        XCTAssertEqual(try ASCMHL.pendingTransferPayloads(root:root).count,1)
        XCTAssertEqual(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new).pendingTransfers,0)
        XCTAssertTrue(try ASCMHL.pendingTransferPayloads(root:root).isEmpty)
    }
    func testMissingOriginalGenerationOrPeerCannotBeHidden()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        let destination=root.appendingPathComponent("B/ascmhl/ascmhl_chain.xml")
        try FileManager.default.removeItem(at:destination);XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testExactRetirementNeverIgnoresSameBasenameElsewhere()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        let other=root.appendingPathComponent("A/elsewhere/ไทย & [x]*.bin")
        try FileManager.default.createDirectory(at:other.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("unlisted".utf8).write(to:other)
        XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testCompletedOperationIsNotAppliedTwice()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        let count=try ASCMHL.load(root:root).generations.count
        XCTAssertThrowsError(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new))
        XCTAssertEqual(try ASCMHL.load(root:root).generations.count,count)
    }
    func testStandaloneSourceControllerShowsPartialScopeAndMovedOut()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        let model=ASCMHLVerifier();model.start(root:root.appendingPathComponent("A"));let end=Date().addingTimeInterval(20)
        while model.isRunning && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertEqual(model.movedOutFiles,[String(old.dropFirst(2))]);XCTAssertTrue(model.status.contains("moved out: 1"));XCTAssertTrue(model.status.contains("not a full transfer verification"))
    }
    func testMissingParentReceiptCannotBecomeFullyVerified()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        let generation=try ASCMHL.load(root:root).generations.last!,url=root.appendingPathComponent("ascmhl/"+generation.path),chain=root.appendingPathComponent("ascmhl/ascmhl_chain.xml")
        let document=try XMLDocument(data:Data(contentsOf:url),options:[.nodeLoadExternalEntitiesNever]);document.rootElement()!.elements(forName:"metadata").first!.detach()
        let data=document.xmlData();try data.write(to:url)
        try String(contentsOf:chain).replacingOccurrences(of:generation.c4,with:ASCMHL.c4(data)).write(to:chain,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try ASCMHL.verify(root:root))
    }
    func testForgedRetirementCannotHideUnrelatedSourceFile()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        let owner=root.appendingPathComponent("A"),history=try ASCMHL.load(root:owner),note=history.transfers.first!.note,p=note.payload
        let payload=ASCMHL.TransferPayload(id:p.id,source:"A/stay.txt",destination:p.destination,sourceOwner:p.sourceOwner,destinationOwner:p.destinationOwner,hash:p.hash,originC4:p.originC4,size:p.size)
        let forged=ASCMHL.TransferNote(payload:payload,role:note.role,scope:note.scope)
        let generation=history.generations.last!,url=owner.appendingPathComponent("ascmhl/"+generation.path),chain=owner.appendingPathComponent("ascmhl/ascmhl_chain.xml")
        let document=try XMLDocument(data:Data(contentsOf:url),options:[.nodeLoadExternalEntitiesNever]);let metadata=document.rootElement()!.elements(forName:"metadata").first!
        (metadata.children!.first{$0.kind == .element})!.stringValue=try JSONEncoder().encode([forged]).base64EncodedString()
        let data=document.xmlData();try data.write(to:url)
        try String(contentsOf:chain).replacingOccurrences(of:generation.c4,with:ASCMHL.c4(data)).write(to:chain,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try ASCMHL.verify(root:owner))
    }
    func testOnwardTransferAfterRenameKeepsEarlierReceiptVerified()throws {
        let(old,new)=try seed(third:true);_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        try FileManager.default.moveItem(at:root.appendingPathComponent(new),to:root.appendingPathComponent("B/renamed.bin"))
        _=try ASCMHL.recordRename(root:root,previousPath:new,newPath:"B/renamed.bin")
        try FileManager.default.moveItem(at:root.appendingPathComponent("B/renamed.bin"),to:root.appendingPathComponent("C/final.bin"))
        let result=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:"B/renamed.bin",newPath:"C/final.bin")
        XCTAssertEqual(result.transferLinks,2);XCTAssertEqual(result.pendingTransfers,0)
    }
    func testRetiredPathReuseIsRejectedBeforeChangingHistory()throws {
        let(old,new)=try seed();_=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new)
        let chain=root.appendingPathComponent("ascmhl/ascmhl_chain.xml"),before=try Data(contentsOf:chain)
        try FileManager.default.moveItem(at:root.appendingPathComponent(new),to:root.appendingPathComponent(old))
        XCTAssertThrowsError(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:new,newPath:old))
        XCTAssertEqual(try Data(contentsOf:chain),before)
    }
    func testSourceMustAlreadyBeMoved()throws {
        let(old,new)=try seed();try FileManager.default.copyItem(at:root.appendingPathComponent(new),to:root.appendingPathComponent(old))
        XCTAssertThrowsError(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new))
    }
    func testTraversalAndSameOwnerRejected()throws {
        let(old,new)=try seed();XCTAssertThrowsError(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:"../outside"))
        try FileManager.default.moveItem(at:root.appendingPathComponent(new),to:root.appendingPathComponent("A/inside.bin"));XCTAssertThrowsError(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:"A/inside.bin"))
    }
    func testRetryAfterInterruptedDestinationCommitCompletesWithoutFalseSuccess()throws {
        let(old,new)=try seed();var interrupted=false
        XCTAssertThrowsError(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new,checkpoint:{
            if !interrupted,let h=try? ASCMHL.load(root:self.root.appendingPathComponent("B")),!h.transfers.isEmpty {interrupted=true;throw CopyError.cancelled}
        }))
        XCTAssertTrue(interrupted);XCTAssertThrowsError(try ASCMHL.verify(root:root))
        XCTAssertEqual(try ASCMHL.recordCrossHistoryMove(root:root,previousPath:old,newPath:new).pendingTransfers,0)
    }
}
