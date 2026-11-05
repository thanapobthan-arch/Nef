import Foundation
import Combine

struct TransferJobSettings:Codable {
    let sources:[URL]
    let destinations:[URL]
    let verify:Bool
    let ascMHLEnabled:Bool?
    let independentSourceVerification:Bool?
    let strategy:TransferStrategy
    let schedule:VerificationSchedule
    let buffer:IOBufferSize
    let includeThumbnails:Bool
    let cascadePrimaryDestination:URL?

    init(sources:[URL],destinations:[URL],verify:Bool=true,
         strategy:TransferStrategy = .singleReadFanOut,
         schedule:VerificationSchedule = .afterCopy,buffer:IOBufferSize = .automatic,
         includeThumbnails:Bool=false,cascadePrimaryDestination:URL?=nil,independentSourceVerification:Bool=false,ascMHLEnabled:Bool=false) {
        self.ascMHLEnabled=ascMHLEnabled
        self.independentSourceVerification=independentSourceVerification
        self.sources=sources;self.destinations=destinations;self.verify=verify
        self.strategy=strategy;self.schedule=schedule;self.buffer=buffer
        self.includeThumbnails=includeThumbnails;self.cascadePrimaryDestination=cascadePrimaryDestination
    }
    init(engine:CopyEngine) {
        self.init(sources:engine.sourceURLs,destinations:engine.destinations.map{$0.url},
                  verify:engine.verifyEnabled,strategy:engine.transferStrategy,
                  schedule:engine.verificationSchedule,buffer:engine.ioBufferSize,
                  includeThumbnails:engine.includeThumbnails,cascadePrimaryDestination:engine.cascadePrimaryDestination,independentSourceVerification:engine.independentSourceVerification,ascMHLEnabled:engine.ascMHLEnabled)
    }
}

enum QueuedJobState:String,Codable {
    case queued="Queued",running="Running",verified="Verified"
    case copied="Copied — not verified",failed="Failed",cancelled="Cancelled"
    var isTerminal:Bool {self != .queued && self != .running}
}

struct QueuedTransferJob:Identifiable {
    let id:UUID
    let settings:TransferJobSettings
    let name:String
    var state:QueuedJobState = .queued
    var engine:CopyEngine?
    var startedAt:Date?
    var finishedAt:Date?
    var error:String?
    var savedReports:[URL]=[]
    var cascadeCheckpoint:CascadeCheckpoint?
    var recovered=false
    var cancellationRequested=false
    var volumes:[String:VolumeIdentity]=[:]
    var reportURLs:[URL] {
        guard let engine else{return savedReports}
        let rows=engine.destinationProgress.compactMap{$0.report}
        return rows.isEmpty ? engine.lastReportURL.map{[$0]} ?? []:rows
    }
}

// Volume UUID protects against a different drive mounted under the same path.
struct VolumeIdentity:Codable,Equatable {
    let uuid:String?
    let device:UInt64
    init?(url:URL) {
        guard let attrs=try? FileManager.default.attributesOfFileSystem(forPath:url.path),
              let number=attrs[.systemNumber] as? NSNumber else{return nil}
        uuid=(try? url.resourceValues(forKeys:[.volumeUUIDStringKey]))?.volumeUUIDString
        device=number.uint64Value
    }
    func matches(_ current:VolumeIdentity)->Bool {
        if let uuid {return current.uuid == uuid}
        return current.device == device
    }
}
private struct StoredQueue:Codable {
    let version:Int
    let paused:Bool
    let jobs:[StoredJob]
}
private struct StoredJob:Codable {
    let id:UUID
    let settings:TransferJobSettings
    let name:String
    let state:QueuedJobState
    let startedAt:Date?
    let finishedAt:Date?
    let error:String?
    let reports:[URL]
    let cancellationRequested:Bool
    let cascadeCheckpoint:CascadeCheckpoint?
    let volumes:[String:VolumeIdentity]
    init(_ job:QueuedTransferJob) {
        id=job.id;settings=job.settings;name=job.name;state=job.state
        startedAt=job.startedAt;finishedAt=job.finishedAt;error=job.error
        reports=job.reportURLs;cancellationRequested=job.cancellationRequested;volumes=job.volumes
        cascadeCheckpoint=job.cascadeCheckpoint
    }
    var restored:QueuedTransferJob {
        var job=QueuedTransferJob(id:id,settings:settings,name:name)
        job.state=cancellationRequested ? .cancelled:(state == .running ? .queued:state)
        job.startedAt=state == .running ? nil:startedAt;job.finishedAt=finishedAt
        job.error=error;job.savedReports=reports;job.recovered=true
        job.cancellationRequested=cancellationRequested;job.volumes=volumes;job.cascadeCheckpoint=cascadeCheckpoint
        return job
    }
}

// Main-thread coordinator. Each queued job owns an immutable settings snapshot
// and a fresh engine. The next job starts only after the prior engine has drained.
final class TransferQueue:ObservableObject {
    let draft:CopyEngine
    @Published private(set) var jobs:[QueuedTransferJob]=[]
    @Published private(set) var activeJobID:UUID?
    @Published private(set) var displayedEngine:CopyEngine?
    @Published private(set) var isQueuePaused:Bool
    @Published private(set) var errorMessage:String?
    static var defaultStorageURL:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("NefCopy/transfer-queue-v1.json")
    }
    private let storageURL:URL?
    private var corruptStorage=false
    private var persistenceFailed=false
    private let makeEngine:(TransferJobSettings)->CopyEngine
    private var draftSubscription:AnyCancellable?
    private var engineSubscription:AnyCancellable?
    private var timer:DispatchSourceTimer?

    var hasPending:Bool {jobs.contains{$0.state == .queued}}
    var isBusy:Bool {activeJobID != nil}
    var canEjectDisplayedSources:Bool {
        guard !isBusy,!hasPending,displayedEngine?.canSafeEject == true else{return false}
        // A successful last job must not hide an earlier unresolved failure or
        // copy-only job. A later verified job covering its paths resolves it.
        return jobs.indices.allSatisfy { index in
            let job=jobs[index]
            if job.state == .verified {return true}
            let sources=Set(job.settings.sources.map{$0.standardizedFileURL.path})
            let destinations=Set(job.settings.destinations.map{$0.standardizedFileURL.path})
            return jobs.dropFirst(index+1).contains { later in
                later.state == .verified && sources.isSubset(of:Set(later.settings.sources.map{$0.standardizedFileURL.path})) && destinations.isSubset(of:Set(later.settings.destinations.map{$0.standardizedFileURL.path}))
            }
        }
    }

    init(storageURL:URL?=TransferQueue.defaultStorageURL,draft:CopyEngine=CopyEngine(),startPaused:Bool=false,
         makeEngine:@escaping (TransferJobSettings)->CopyEngine = {_ in CopyEngine()}) {
        self.storageURL=storageURL
        self.draft=draft;self.isQueuePaused=startPaused;self.makeEngine=makeEngine
        restore()
        if hasPending && !isQueuePaused {
            DispatchQueue.main.async { [weak self] in self?.startNextIfPossible() }
        }
        draftSubscription=draft.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    deinit {timer?.cancel()}

    private func restore() {
        guard let storageURL,FileManager.default.fileExists(atPath:storageURL.path) else{return}
        do {
            let size=(try FileManager.default.attributesOfItem(atPath:storageURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size<=10*1024*1024 else{throw CocoaError(.fileReadCorruptFile)}
            let snapshot=try JSONDecoder().decode(StoredQueue.self,from:Data(contentsOf:storageURL))
            guard snapshot.version==1,Set(snapshot.jobs.map{$0.id}).count==snapshot.jobs.count,
                  snapshot.jobs.allSatisfy({!$0.settings.sources.isEmpty && !$0.settings.destinations.isEmpty &&
                      ($0.settings.sources+$0.settings.destinations).allSatisfy{$0.isFileURL}}) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            jobs=snapshot.jobs.map{$0.restored};isQueuePaused=snapshot.paused
        } catch {
            corruptStorage=true;isQueuePaused=true
            errorMessage="Saved queue could not be read. It has been preserved at \(storageURL.path). \(error.localizedDescription)"
        }
    }
    // Save before starting work and at every queue transition, including cancellation
    // intent. Atomic replacement leaves the previous complete snapshot on interruption.
    @discardableResult
    private func persist()->Bool {
        guard !corruptStorage else{isQueuePaused=true;return false}
        guard let storageURL else{return true}
        do {
            let snapshot=StoredQueue(version:1,paused:isQueuePaused || (isBusy && displayedEngine?.isPaused == true),jobs:jobs.map{StoredJob($0)})
            let data=try JSONEncoder().encode(snapshot)
            guard data.count<=10*1024*1024 else {throw CopyError.verifyFailed("Saved queue exceeds 10 MiB. Remove old queue records before retrying.")}
            try FileManager.default.createDirectory(at:storageURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:storageURL,options:.atomic)
            if persistenceFailed {errorMessage=nil}
            persistenceFailed=false;return true
        } catch {
            persistenceFailed=true;isQueuePaused=true
            errorMessage="Could not save queue. New jobs are paused; free space or restore access, then Resume Queue. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func enqueue(_ settings:TransferJobSettings,name:String?=nil) -> UUID? {
        assert(Thread.isMainThread)
        guard !corruptStorage else{return nil}
        guard !settings.sources.isEmpty,!settings.destinations.isEmpty else {
            errorMessage="Choose at least one source and one destination.";return nil
        }
        guard settings.sources.allSatisfy({$0.isFileURL}),settings.destinations.allSatisfy({$0.isFileURL}) else {
            errorMessage="Choose local file or folder locations.";return nil
        }
        let id=UUID()
        let title=name ?? settings.sources.map{$0.lastPathComponent}.joined(separator:", ")
        var job=QueuedTransferJob(id:id,settings:settings,name:title)
        for url in settings.sources+settings.destinations {
            job.volumes[url.standardizedFileURL.path]=VolumeIdentity(url:url)
        }
        jobs.append(job)
        errorMessage=nil
        guard persist() else{return id}
        startNextIfPossible();return id
    }
    @discardableResult
    func enqueueDraft()->UUID? {enqueue(TransferJobSettings(engine:draft))}

    func pauseQueue() {assert(Thread.isMainThread);isQueuePaused=true;persist()}
    func resumeQueue() {assert(Thread.isMainThread);isQueuePaused=false;if persist(){startNextIfPossible()}}
    func pauseActive() {guard isBusy else{return};displayedEngine?.pauseTransfer();persist()}
    func resumeActive() {guard isBusy else{return};displayedEngine?.resumeTransfer();persist()}
    func cancelJob(_ id:UUID) {
        assert(Thread.isMainThread)
        guard let index=jobs.firstIndex(where:{$0.id==id}) else{return}
        if activeJobID==id {jobs[index].cancellationRequested=true;persist();jobs[index].engine?.cancel()}
        else if jobs[index].state == .queued {jobs[index].state = .cancelled;jobs[index].finishedAt=Date()}
        persist()
    }
    func cancelAll() {
        assert(Thread.isMainThread)
        isQueuePaused=true
        for index in jobs.indices where jobs[index].state == .queued {
            jobs[index].state = .cancelled;jobs[index].finishedAt=Date()
        }
        if let id=activeJobID {cancelJob(id)}
        persist()
    }
    func removeJob(_ id:UUID) {
        assert(Thread.isMainThread)
        guard activeJobID != id else{return}
        jobs.removeAll{$0.id==id};persist()
    }
    @discardableResult
    func clearInactiveJobs()->Bool {
        assert(Thread.isMainThread)
        guard !corruptStorage else{return false}
        let previous=jobs
        jobs.removeAll{$0.id != activeJobID}
        guard persist() else {jobs=previous;return false}
        if activeJobID == nil {displayedEngine=nil;engineSubscription=nil}
        return true
    }
    var canClearTransferHistory:Bool {!isBusy && !draft.isRunning && !jobs.contains{$0.engine?.isRunning == true}}
    func reloadTransferHistory() {
        draft.reloadTransferHistory()
        for job in jobs {job.engine?.reloadTransferHistory()}
        displayedEngine?.reloadTransferHistory()
    }
    func clearTransferHistory()throws {
        guard canClearTransferHistory else{throw CopyError.verifyFailed("Wait for the active transfer before clearing history.")}
        try draft.clearTransferHistory();reloadTransferHistory()
    }
    func moveWaitingJob(_ id:UUID,earlier:Bool) {
        assert(Thread.isMainThread)
        let waiting=jobs.indices.filter{jobs[$0].state == .queued}
        guard let pos=waiting.firstIndex(where:{jobs[$0].id==id}) else{return}
        let target=pos+(earlier ? -1:1)
        guard waiting.indices.contains(target) else{return}
        jobs.swapAt(waiting[pos],waiting[target]);persist()
    }
    // Reassign only waiting slots; active and terminal jobs never move.
    @discardableResult
    func moveWaitingJob(_ id:UUID,before target:UUID?)->Bool {
        assert(Thread.isMainThread)
        guard !corruptStorage,id != target else{return false}
        let previous=jobs
        let slots=jobs.indices.filter{jobs[$0].state == .queued}
        var waiting=slots.map{jobs[$0]}
        guard let from=waiting.firstIndex(where:{$0.id==id}) else{return false}
        if let target, !waiting.contains(where:{$0.id==target}) {return false}
        let moving=waiting.remove(at:from)
        let to=target.flatMap{id in waiting.firstIndex(where:{$0.id==id})} ?? waiting.count
        waiting.insert(moving,at:to)
        for (slot,job) in zip(slots,waiting) {jobs[slot]=job}
        guard persist() else {jobs=previous;return false}
        return true
    }

    // Save all source jobs in one snapshot before any of them may start.
    @discardableResult
    func enqueueSourceBatch(_ settings:TransferJobSettings)->[UUID] {
        assert(Thread.isMainThread)
        guard !corruptStorage,!settings.sources.isEmpty,!settings.destinations.isEmpty,
              (settings.sources+settings.destinations).allSatisfy({$0.isFileURL}) else {
            errorMessage="Choose local sources and destinations.";return []
        }
        var added:[UUID]=[]
        for source in settings.sources {
            let spec=TransferJobSettings(sources:[source],destinations:settings.destinations,verify:settings.verify,
                strategy:settings.strategy,schedule:settings.schedule,buffer:settings.buffer,
                includeThumbnails:settings.includeThumbnails,cascadePrimaryDestination:settings.cascadePrimaryDestination,
                independentSourceVerification:settings.independentSourceVerification ?? false,ascMHLEnabled:settings.ascMHLEnabled ?? false)
            var job=QueuedTransferJob(id:UUID(),settings:spec,name:source.lastPathComponent)
            for url in spec.sources+spec.destinations {job.volumes[url.standardizedFileURL.path]=VolumeIdentity(url:url)}
            jobs.append(job);added.append(job.id)
        }
        errorMessage=nil
        guard persist() else {jobs.removeAll{added.contains($0.id)};return []}
        startNextIfPossible();return added
    }

    @discardableResult
    func retryJob(_ id:UUID)->UUID? {
        guard let job=jobs.first(where:{$0.id==id}),job.state == .failed || job.state == .cancelled else{return nil}
        let id=enqueueRetry(job)
        return id
    }
    private func enqueueRetry(_ original:QueuedTransferJob)->UUID? {
        guard !corruptStorage else{return nil}
        var job=QueuedTransferJob(id:UUID(),settings:original.settings,name:original.name+" — retry")
        job.recovered=true;job.volumes=original.volumes;job.cascadeCheckpoint=original.cascadeCheckpoint
        jobs.append(job)
        if persist(){startNextIfPossible()}
        return job.id
    }
    private func startNextIfPossible() {
        guard !corruptStorage,!persistenceFailed,!isQueuePaused,activeJobID==nil,let index=jobs.firstIndex(where:{$0.state == .queued}) else{return}
        if jobs[index].recovered {
            let settings=jobs[index].settings
            if let checkpoint=jobs[index].cascadeCheckpoint {
                do {
                    guard settings.strategy == .cascading,settings.verify else {throw CopyError.verifyFailed("SSD checkpoint requires verified Cascading.")}
                    try checkpoint.validate(sources:settings.sources,destinations:settings.destinations,primary:settings.cascadePrimaryDestination)
                } catch {
                    jobs[index].state = .failed;jobs[index].error=error.localizedDescription;jobs[index].finishedAt=Date()
                    if persist(){DispatchQueue.main.async { [weak self] in self?.startNextIfPossible() }}
                    return
                }
            }
            let locations=(jobs[index].cascadeCheckpoint == nil ? settings.sources:[])+settings.destinations
            let invalid=locations.first { url in
                guard let saved=jobs[index].volumes[url.standardizedFileURL.path],let current=VolumeIdentity(url:url) else{return true}
                return !saved.matches(current)
            }
            if let invalid {
                jobs[index].state = .failed;jobs[index].finishedAt=Date()
                jobs[index].error="Saved location is missing or its drive has changed: \(invalid.path). Reconnect the original drive and Retry."
                if persist() {DispatchQueue.main.async { [weak self] in self?.startNextIfPossible() }}
                return
            }
        }
        let settings=jobs[index].settings,engine=makeEngine(settings)
        engine.partialFileNamespace=jobs[index].id.uuidString
        engine.revalidateExistingFiles=jobs[index].recovered
        engine.sourceURLs=settings.sources
        engine.destinations=settings.destinations.map{Destination(url:$0)}
        engine.independentSourceVerification=settings.independentSourceVerification ?? false
        engine.ascMHLEnabled=settings.ascMHLEnabled ?? false
        engine.verifyEnabled=settings.verify;engine.transferStrategy=settings.strategy
        engine.verificationSchedule=settings.schedule;engine.ioBufferSize=settings.buffer
        engine.includeThumbnails=settings.includeThumbnails
        engine.cascadePrimaryDestination=settings.cascadePrimaryDestination
        engine.cascadeCheckpoint=jobs[index].cascadeCheckpoint
        let id=jobs[index].id
        engine.saveCascadeCheckpoint={ [weak self] checkpoint in
            guard let self,let current=self.jobs.firstIndex(where:{$0.id==id}) else {throw CopyError.verifyFailed("Queue is unavailable; SSD handoff was not saved.")}
            self.jobs[current].cascadeCheckpoint=checkpoint
            guard self.persist() else {throw CopyError.verifyFailed("Could not save SSD checkpoint. Original source is still required.")}
        }
        jobs[index].engine=engine;jobs[index].state = .running;jobs[index].startedAt=Date()
        activeJobID=id;displayedEngine=engine
        engineSubscription=engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        guard persist() else {
            jobs[index].state = .queued;activeJobID=nil;jobs[index].engine=nil
            return
        }
        engine.start()
        let source=DispatchSource.makeTimerSource(queue:.main)
        timer=source;source.schedule(deadline:.now(),repeating:.milliseconds(20))
        source.setEventHandler { [weak self] in self?.checkCompletion() }
        source.resume()
    }
    private func checkCompletion() {
        guard let id=activeJobID,let index=jobs.firstIndex(where:{$0.id==id}),let engine=jobs[index].engine,!engine.isRunning else{return}
        // Do not infer success from a stopped worker, 100%, or an idle preflight.
        switch engine.state {
        case .completed:jobs[index].state = engine.lastRunWasVerified ? .verified:.copied
        case .cancelled:jobs[index].state = .cancelled
        default:jobs[index].state = .failed
        }
        jobs[index].error=engine.errorMessage;jobs[index].finishedAt=Date()
        timer?.cancel();timer=nil;engineSubscription=nil;activeJobID=nil
        // Completion state/report publication precedes the next engine's start.
        if persist(){startNextIfPossible()}
    }
}
