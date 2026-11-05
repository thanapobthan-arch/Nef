import XCTest
@testable import NefCopy
final class DiskActionsTests:XCTestCase {
    private let a=URL(fileURLWithPath:"/Volumes/NefTest-A"),b=URL(fileURLWithPath:"/Volumes/NefTest-B")
    private func wait(_ model:DiskActions) {
        let end=Date().addingTimeInterval(5)
        while model.isEjecting && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertFalse(model.isEjecting)
    }
    func testContainingVolumeIsDeduplicatedForSelectedFolders() {
        let result=DiskActions.targets([a.appendingPathComponent("camera"),a.appendingPathComponent("backup"),b],resolve:{$0.path.hasPrefix(self.a.path) ? self.a:self.b})
        XCTAssertEqual(result,[a,b])
    }
    func testSystemUnknownAndNonFileURLsAreRejected() {
        let inputs=[URL(fileURLWithPath:"/"),URL(fileURLWithPath:"/System/Volumes/Data"),URL(fileURLWithPath:"/Volumes/Drive/subfolder"),URL(string:"https://example.com")!]
        XCTAssertTrue(DiskActions.targets(inputs,resolve:{$0}).isEmpty)
        XCTAssertTrue(DiskActions.targets([a],resolve:{_ in nil}).isEmpty)
        XCTAssertNil(DiskActions.externalVolume(URL(fileURLWithPath:"/")))
    }
    func testBlockedOperationDoesNotConfirmOrEject() {
        let model=DiskActions();model.start(urls:[a],blocked:true,resolve:{$0},confirm:{_ in XCTFail("blocked confirmation");return true},eject:{_ in XCTFail("blocked eject")})
        XCTAssertFalse(model.isEjecting)
    }
    func testCancelMakesNoEjectCalls() {
        let model=DiskActions();model.start(urls:[a],blocked:false,resolve:{$0},confirm:{XCTAssertEqual($0,[self.a]);return false},eject:{_ in XCTFail("cancelled eject")})
        XCTAssertFalse(model.isEjecting);XCTAssertEqual(model.status,"Eject cancelled.")
    }
    func testNoEligibleVolumesMakesNoCalls() {
        let model=DiskActions();model.start(urls:[a],blocked:false,resolve:{_ in nil},confirm:{_ in XCTFail("empty confirm");return true},eject:{_ in XCTFail("empty eject")})
        XCTAssertFalse(model.isEjecting)
    }
    func testFailureDoesNotStopOtherVolumesAndReportsPartialResult() {
        let model=DiskActions(),lock=NSLock();var calls:[URL]=[];var finished=false
        model.start(urls:[b,a,a],blocked:false,resolve:{$0},confirm:{_ in true},eject:{url in
            lock.lock();calls.append(url);lock.unlock()
            if url==self.a {throw NSError(domain:"NefTest",code:1,userInfo:[NSLocalizedDescriptionKey:"disk busy"])}
        },completion:{message,failed in
            XCTAssertTrue(Thread.isMainThread);XCTAssertTrue(failed);XCTAssertTrue(message.contains("disk busy"));XCTAssertTrue(message.contains("Ejected: NefTest-B"));finished=true
        })
        wait(model);XCTAssertTrue(finished);XCTAssertEqual(calls,[a,b])
    }
    func testConcurrentInvocationIsIgnored() {
        let model=DiskActions();var count=0
        model.start(urls:[a],blocked:false,resolve:{$0},confirm:{_ in true},eject:{_ in Thread.sleep(forTimeInterval:0.03)})
        model.start(urls:[b],blocked:false,resolve:{$0},confirm:{_ in count+=1;return true},eject:{_ in XCTFail("second eject")})
        wait(model);XCTAssertEqual(count,0)
    }
}
