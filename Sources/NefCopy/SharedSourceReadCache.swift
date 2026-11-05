import Foundation

// A per-job cache, shared only by destination copy workers. Lagging workers may
// reread evicted chunks; no writer, destination failure, or pause owns this lock.
final class SharedSourceReadCache {
    private struct Key:Hashable {let path:String;let offset:UInt64;let count:Int}
    private struct Entry {let data:Data;var access:UInt64}
    private final class Flight {var result:Result<Data,Error>?}
    struct Statistics {let hits:Int;let coalesced:Int;let readBytes:Int64;let peakCachedBytes:Int;let cachedBytes:Int}
    private let condition=NSCondition()
    private let capacity:Int
    private var cache:[Key:Entry]=[:]
    private var inFlight:[Key:Flight]=[:]
    private var clock:UInt64=0
    private var retained=0,peak=0,hits=0,coalesced=0
    private var bytes:Int64=0

    init(capacityBytes:Int=64*1024*1024) {capacity=max(0,capacityBytes)}
    var statistics:Statistics {
        condition.lock();defer{condition.unlock()}
        return Statistics(hits:hits,coalesced:coalesced,readBytes:bytes,peakCachedBytes:peak,cachedBytes:retained)
    }
    func read(source:URL,offset:UInt64,count:Int,checkpoint:() throws->Void,
              load:() throws->Data)throws->Data {
        try checkpoint()
        let key=Key(path:source.standardizedFileURL.path,offset:offset,count:count)
        condition.lock()
        if var entry=cache[key] {
            clock &+= 1;entry.access=clock;cache[key]=entry;hits+=1
            condition.unlock();return entry.data
        }
        if let flight=inFlight[key] {
            coalesced+=1
            while flight.result == nil {
                _=condition.wait(until:Date().addingTimeInterval(0.05))
                condition.unlock()
                try checkpoint()
                condition.lock()
            }
            let result=flight.result!
            condition.unlock()
            switch result {
            case .success(let data):return data
            case .failure:
                // Cancellation/read failure belongs to the reader that loaded
                // this flight. A healthy destination retries with its own handle.
                return try read(source:source,offset:offset,count:count,checkpoint:checkpoint,load:load)
            }
        }
        let flight=Flight();inFlight[key]=flight
        condition.unlock()
        let result=Result {try checkpoint();return try load()}
        condition.lock()
        if case .success(let data)=result {
            bytes+=Int64(data.count)
            // EOF entries are not cached. Also cap entry count for tiny files.
            if !data.isEmpty && data.count<=capacity {
                while retained+data.count>capacity || cache.count>=256 {
                    guard let victim=cache.min(by:{$0.value.access<$1.value.access}) else{break}
                    retained-=victim.value.data.count;cache.removeValue(forKey:victim.key)
                }
                clock &+= 1;cache[key]=Entry(data:data,access:clock)
                retained+=data.count;peak=max(peak,retained)
            }
        }
        flight.result=result;inFlight.removeValue(forKey:key)
        condition.broadcast();condition.unlock()
        return try result.get()
    }
}

// Counts bytes returned by source copy-read APIs, not physical device traffic.
final class SourceReadMetrics {
    private let lock=NSLock()
    private var bytes:Int64=0
    func add(_ value:Int) {lock.lock();bytes+=Int64(value);lock.unlock()}
    func reset() {lock.lock();bytes=0;lock.unlock()}
    var readBytes:Int64 {lock.lock();defer{lock.unlock()};return bytes}
}
