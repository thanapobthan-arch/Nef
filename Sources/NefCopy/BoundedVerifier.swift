import Foundation
import DiskArbitration

// Ready operations may run on different devices, but each device lane is serial.
// Only this class owns verification handles. The transfer thread owns engine/UI
// counters; it polls progress and consumes one result per temporary file.
final class BoundedVerifier {
    private let queue:OperationQueue
    private let sharedBudget:Bool
    private let slots=DispatchSemaphore(value:2)
    private let group=DispatchGroup()
    private let condition=NSCondition()
    private var lastByDevice:[String:Operation]=[:]
    private var submitted=Set<URL>()
    private var outcomes:[URL:Result<String,Error>]=[:]
    private var bytes:Int64=0
    private var seconds:TimeInterval=0
    private var active=0
    private var clock=ProcessInfo.processInfo.systemUptime
#if DEBUG
    var testDelayPerChunk:TimeInterval=0
    var testWorkerObserver:((String,Bool)->Void)?
#endif

    init(maxConcurrentReads:Int=4,sharedBudget:Bool=false) {
        self.sharedBudget=sharedBudget
        queue=OperationQueue()
        queue.name="local.nefcopy.verify"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount=max(1,min(4,maxConcurrentReads))
    }

    // Whole-disk/container identity groups folders and partitions on the same
    // device. Unknown storage is deliberately serialized in one fallback lane.
    static func deviceKey(for url:URL)->String {
        guard let volume=try? url.resourceValues(forKeys:[.volumeURLKey]).volume,
              let session=DASessionCreate(kCFAllocatorDefault),
              let disk=DADiskCreateFromVolumePath(kCFAllocatorDefault,session,volume as CFURL) else { return "unknown-storage" }
        let whole=DADiskCopyWholeDisk(disk) ?? disk
        // The BSD-name pointer belongs to the DADisk; retain that owner until
        // copying the bytes, including when CopyWholeDisk returned a new object.
        return withExtendedLifetime(whole) {
            guard let name=DADiskGetBSDName(whole) else { return "unknown-storage" }
            let value=String(cString:name)
            return value.hasPrefix("disk") ? value : "unknown-storage"
        }
    }

    private func accountTime() {
        let now=ProcessInfo.processInfo.systemUptime
        if active>0 { seconds += now-clock }
        clock=now
    }

    // Streaming submissions retain backpressure. A completed-copy batch already
    // has a bounded inventory of pending files, so it queues lightweight operations
    // without holding file handles/buffers or blocking other device lanes.
    func submit(_ url:URL,buffer:Int,corrupt:Bool=false,isCancelled:@escaping () -> Bool,
                deviceKey:String?=nil,bounded:Bool=true,checkpoint:(() throws -> Void)?=nil) throws {
        if bounded {
            while slots.wait(timeout:.now()+0.05) == .timedOut {
                if isCancelled() { throw CopyError.cancelled }
            }
        }
        if isCancelled() { if bounded { slots.signal() }; throw CopyError.cancelled }
        let key=deviceKey ?? Self.deviceKey(for:url)
#if DEBUG
        let delay=testDelayPerChunk, observer=testWorkerObserver
#endif
        condition.lock()
        guard !submitted.contains(url) else {
            condition.unlock(); if bounded { slots.signal() }; throw CocoaError(.fileWriteFileExists)
        }
        submitted.insert(url)
        group.enter()
        let operation=BlockOperation { [self] in
            defer { if bounded { slots.signal() }; group.leave() }
            condition.lock(); accountTime(); active += 1; condition.unlock()
#if DEBUG
            observer?(key,true)
#endif
            let result=Result<String,Error> {
                let release=sharedBudget ? try VerificationReadBudget.acquire(key:key,checkpoint:{
                    try checkpoint?();if isCancelled() {throw CopyError.cancelled}
                }):nil
                defer {release?()}
                try checkpoint?()
                if isCancelled() { throw CopyError.cancelled }
                if corrupt {
                    let h=try FileHandle(forWritingTo:url)
                    defer { try? h.close() }
                    try h.write(contentsOf:Data([0])); try h.synchronize()
                }
                let h=try FileHandle(forReadingFrom:url)
                defer { try? h.close() }
                let hasher=XXH64BE()
                while true {
                    try checkpoint?()
                    if isCancelled() { throw CopyError.cancelled }
                    let data=try autoreleasepool { try h.read(upToCount:buffer) ?? Data() }
                    if data.isEmpty { break }
                    hasher.update(data:data)
                    condition.lock(); bytes += Int64(data.count); condition.unlock()
#if DEBUG
                    if delay>0 { Thread.sleep(forTimeInterval:delay) }
#endif
                }
                return hasher.finalize().map{String(format:"%02x",$0)}.joined()
            }
#if DEBUG
            observer?(key,false)
#endif
            condition.lock(); accountTime(); active -= 1
            outcomes[url]=result; condition.broadcast(); condition.unlock()
        }
        if let previous=lastByDevice[key] { operation.addDependency(previous) }
        lastByDevice[key]=operation
        condition.unlock()
        queue.addOperation(operation)
    }

    func result(for url:URL,onWait:() -> Void = {}) throws -> String {
        condition.lock()
        guard submitted.contains(url) else { condition.unlock(); throw CocoaError(.fileReadUnknown) }
        while outcomes[url] == nil {
            _=condition.wait(until:Date().addingTimeInterval(0.05))
            condition.unlock(); onWait(); condition.lock()
        }
        let result=outcomes.removeValue(forKey:url)
        submitted.remove(url)
        condition.unlock()
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
    func takeProgress() -> (bytes:Int64,seconds:TimeInterval) {
        condition.lock(); defer { condition.unlock() }
        accountTime()
        let result=(bytes,seconds); bytes=0; seconds=0; return result
    }
    func waitForAll() { group.wait() }
}
