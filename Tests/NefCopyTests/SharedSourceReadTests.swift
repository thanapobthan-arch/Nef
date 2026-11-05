import XCTest
import CryptoKit
@testable import NefCopy

final class SharedSourceReadTests:XCTestCase {
    private let source=URL(fileURLWithPath:"/test/source.bin")
    func testRepeatedChunkIsLoadedOnceAndBytesMatch()throws {
        let cache=SharedSourceReadCache(capacityBytes:1024),expected=Data(repeating:27,count:256)
        var reads=0
        for _ in 0..<3 {
            let data=try cache.read(source:source,offset:0,count:256,checkpoint:{},load:{reads+=1;return expected})
            XCTAssertEqual(SHA256.hash(data:data),SHA256.hash(data:expected))
        }
        XCTAssertEqual(reads,1);XCTAssertEqual(cache.statistics.readBytes,256);XCTAssertEqual(cache.statistics.hits,2)
    }
    func testSimultaneousReadersCoalesce() {
        let cache=SharedSourceReadCache(),gate=DispatchSemaphore(value:0)
        let entered=expectation(description:"loader"),done=expectation(description:"readers");done.expectedFulfillmentCount=2
        let data=Data(repeating:65,count:1024)
        DispatchQueue.global().async {
            defer{done.fulfill()}
            do {XCTAssertEqual(try cache.read(source:self.source,offset:0,count:1024,checkpoint:{},load:{entered.fulfill();gate.wait();return data}),data)} catch {XCTFail("\(error)")}
        }
        wait(for:[entered],timeout:5)
        DispatchQueue.global().async {
            defer{done.fulfill()}
            do {XCTAssertEqual(try cache.read(source:self.source,offset:0,count:1024,checkpoint:{},load:{XCTFail("Duplicate read");return data}),data)} catch {XCTFail("\(error)")}
        }
        let deadline=Date().addingTimeInterval(5)
        while cache.statistics.coalesced==0 && Date()<deadline {Thread.sleep(forTimeInterval:0.001)}
        XCTAssertEqual(cache.statistics.coalesced,1);gate.signal()
        wait(for:[done],timeout:5);XCTAssertEqual(cache.statistics.readBytes,1024)
    }
    func testCancelledLoaderDoesNotCancelHealthyReader() {
        let cache=SharedSourceReadCache(),gate=DispatchSemaphore(value:0)
        let entered=expectation(description:"loader"),done=expectation(description:"both");done.expectedFulfillmentCount=2
        DispatchQueue.global().async {
            defer{done.fulfill()}
            do {
                _=try cache.read(source:self.source,offset:0,count:16,checkpoint:{},load:{entered.fulfill();gate.wait();throw CopyError.cancelled})
                XCTFail("Cancelled reader should fail")
            } catch {XCTAssertTrue(error is CopyError)}
        }
        wait(for:[entered],timeout:5)
        DispatchQueue.global().async {
            defer{done.fulfill()}
            do {XCTAssertEqual(try cache.read(source:self.source,offset:0,count:16,checkpoint:{},load:{Data(repeating:3,count:16)}),Data(repeating:3,count:16))} catch {XCTFail("\(error)")}
        }
        let deadline=Date().addingTimeInterval(5)
        while cache.statistics.coalesced==0 && Date()<deadline {Thread.sleep(forTimeInterval:0.001)}
        XCTAssertEqual(cache.statistics.coalesced,1);gate.signal();wait(for:[done],timeout:5)
    }
    func testLaggingReaderRereadsEvictedChunkWithinMemoryLimit()throws {
        let cache=SharedSourceReadCache(capacityBytes:32)
        var reads=0
        for offset in [0,16,32,0] {
            let actual=try cache.read(source:source,offset:UInt64(offset),count:16,checkpoint:{},load:{reads+=1;return Data(repeating:UInt8(offset),count:16)})
            XCTAssertEqual(actual,Data(repeating:UInt8(offset),count:16))
        }
        XCTAssertEqual(reads,4);XCTAssertEqual(cache.statistics.readBytes,64)
        XCTAssertLessThanOrEqual(cache.statistics.peakCachedBytes,32)
    }
    func testFileAndOffsetArePartOfCacheKey()throws {
        let cache=SharedSourceReadCache()
        for (path,offset,value) in [(source,0,1),(source,8,2),(URL(fileURLWithPath:"/another/source.bin"),0,3)] {
            XCTAssertEqual(try cache.read(source:path,offset:UInt64(offset),count:8,checkpoint:{},load:{Data(repeating:UInt8(value),count:8)}),Data(repeating:UInt8(value),count:8))
        }
        XCTAssertEqual(cache.statistics.readBytes,24)
    }
    func testEmptyReadsAreNotRetainedAndTinyFilesStayBounded()throws {
        let cache=SharedSourceReadCache(capacityBytes:512)
        var emptyLoads=0
        for _ in 0..<10 {_=try cache.read(source:source,offset:0,count:8,checkpoint:{},load:{emptyLoads+=1;return Data()})}
        XCTAssertEqual(emptyLoads,10);XCTAssertEqual(cache.statistics.cachedBytes,0)
        for offset in 0..<1000 {_=try cache.read(source:source,offset:UInt64(offset),count:1,checkpoint:{},load:{Data([1])})}
        XCTAssertLessThanOrEqual(cache.statistics.cachedBytes,256)
    }
    func testCheckpointCancellationDoesNotPoisonCache()throws {
        let cache=SharedSourceReadCache()
        XCTAssertThrowsError(try cache.read(source:source,offset:0,count:8,checkpoint:{throw CopyError.cancelled},load:{XCTFail("Must not read");return Data()}))
        XCTAssertEqual(try cache.read(source:source,offset:0,count:8,checkpoint:{},load:{Data([9])}),Data([9]))
    }
    func testEngineSharesSourceAndVerifiesIndependentDestinations()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SharedSourceEngine-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source"),a=root.appendingPathComponent("a"),b=root.appendingPathComponent("b")
        for url in [source,a,b] {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
        let bytes=Data(repeating:19,count:24*1024*1024)
        try bytes.write(to:source.appendingPathComponent("data.bin"))
        let engine=CopyEngine();engine.sourceURLs=[source];engine.destinations=[Destination(url:a),Destination(url:b)]
        engine.verificationSchedule = .afterCopy;engine.start()
        let deadline=Date().addingTimeInterval(20)
        while engine.isRunning && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
        XCTAssertFalse(engine.isRunning);XCTAssertEqual(engine.state,.completed);XCTAssertTrue(engine.lastRunWasVerified)
        XCTAssertEqual(engine.sourceReadBytes,Int64(bytes.count));XCTAssertEqual(engine.passCount,2)
        XCTAssertLessThanOrEqual(engine.sharedReadStatistics!.peakCachedBytes,64*1024*1024)
        for dest in [a,b] {XCTAssertEqual(SHA256.hash(data:try Data(contentsOf:dest.appendingPathComponent("source/data.bin"))),SHA256.hash(data:bytes))}
    }
}
