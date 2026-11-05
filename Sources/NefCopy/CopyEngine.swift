import Foundation
import Darwin
import AppKit
import Combine

final class CopyEngine: ObservableObject {
    @Published var sourceURLs:[URL]=[]
    @Published var destinations:[Destination]=[]
    @Published var state:JobState = .idle
    @Published var destinationProgress:[DestinationProgress]=[]
    private let writesHistory:Bool
    private var sharedSourceReads:SharedSourceReadCache?
    private var completedSharedReadStatistics:SharedSourceReadCache.Statistics?
    private let sourceReadMetrics=SourceReadMetrics()
    private var completedSourceReadBytes:Int64=0
    var sourceReadBytes:Int64 {
        destinationWorkers.isEmpty ? max(completedSourceReadBytes,sourceReadMetrics.readBytes):destinationWorkers.reduce(0){$0+$1.1.sourceReadMetrics.readBytes}
    }
    var sharedReadStatistics:SharedSourceReadCache.Statistics? {sharedSourceReads?.statistics ?? completedSharedReadStatistics}
#if DEBUG
    var testDisableSharedSourceReads=false
    var testCascadeBeforeForward:((URL)->Void)?
    var testCascadeCorruptPrimary=false
#endif
    private var destinationWorkers:[(Destination,CopyEngine)]=[]
    private var destinationTimer:DispatchSourceTimer?
    private var isolatedFailedDestinations:[Destination]=[]
    private var isolationPreparing=false
    private var disconnectedDestinationPaths=Set<String>()
    private var lastRunWasPartialRetry=false
    private var preparedEntries:[CopyEntry]?
    private var preparedSourceMetadata:[String:(Int64,Double)]=[:]
    private var destinationDeviceIDs:[UUID:UInt64]=[:]
    private var verificationLaneKey="unknown-storage"

    @Published var progress:Double=0
    @Published var currentFile=""
    @Published var statusText="Drop files/folders or choose a source"
    @Published var speedBytesPerSecond:Double=0
    @Published var etaSeconds:Double=0
    @Published var overallEtaSeconds:Double=0
    private var measuredTransferBytes:Int64=0
    private var measuredCopySeconds:Double=0
    private var measuredVerifySeconds:Double=0
    private var transferClockStarted=Date()
    @Published var totalBytes:Int64=0
    @Published var copiedBytes:Int64=0
    @Published var completedFiles=0
    @Published var totalFiles=0
    @Published var errorMessage:String?
    @Published var verifyEnabled=true
    @Published var ascMHLEnabled=false
    private var resumeASCMHL=false
    private var ascMHLManifestPaths:[String]=[]
    private var ascMHLOperationStart=Date()
    @Published var independentSourceVerification=false
    @Published private(set) var independentSourceVerifiedFiles=0
    private let independentSourceReadMetrics=SourceReadMetrics()
    var independentSourceReadBytes:Int64 {independentSourceReadMetrics.readBytes}
    private var sourceReferenceOrigin="None"
    private var sourceReferenceBytes:Int64=0
    private var sourceReferenceFileCount=0
    private var resumeIndependentSourceVerification=false
#if DEBUG
    var testAfterIndependentSourceVerification:(() throws->Void)?
#endif
    @Published var transferStrategy:TransferStrategy = .singleReadFanOut
    @Published var cascadePrimaryDestination:URL?
    @Published private(set) var cascadeSourceReleased=false
    var cascadeCheckpoint:CascadeCheckpoint?
    var saveCascadeCheckpoint:((CascadeCheckpoint)throws->Void)?
    private(set) var cascadeSourceReleasedAt:Date?
    private var cascadeOriginalReadBytes:Int64=0
    private var cascadeReplicaReadBytes:Int64=0
    private var cascadeDependencyFailure:String?
    private var expectedSourceHashes:[String:String]=[:]
    private var verifiedContentHashes:[String:String]=[:]
    var originalSourceReadBytes:Int64 {transferStrategy == .cascading ? cascadeOriginalReadBytes:sourceReadBytes}
    var replicaReadBytes:Int64 {cascadeReplicaReadBytes}
    @Published var lastReportURL:URL?
    @Published var history:[TransferHistoryRecord]=[]
    @Published var mountedDrives:[MountedDrive]=[]
    @Published var elapsedSeconds:Double=0
    @Published var copyProcessingSeconds:Double=0
    @Published var verifyProcessingSeconds:Double=0
    @Published var copiedFileCount=0
    @Published var pendingVerifyFileCount=0
    @Published var passCount=0
    @Published var failCount=0
    @Published var lastRunWasVerified=false
    @Published var preflightProgress:Double=0
    @Published var preflightStatus="Ready"
    @Published private(set) var isPaused=false
    private let pauseCondition=NSCondition()
    private var pauseRequested=false
    private let cancellationLock=NSLock()
    private var cancellationRequested=false
    private var cancelled:Bool {
        get { cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancellationRequested }
        set {
            cancellationLock.lock(); cancellationRequested=newValue; cancellationLock.unlock()
            if newValue { pauseCondition.lock(); pauseRequested=false; pauseCondition.broadcast(); pauseCondition.unlock() }
        }
    }
    @Published var phaseSnapshot=PhaseSnapshot()
    var phaseName:String { get { phaseSnapshot.name } set { phaseSnapshot.name=newValue } }
    var phaseProgress:Double { get { phaseSnapshot.progress } set { phaseSnapshot.progress=newValue } }
    var phaseBytes:Int64 { get { phaseSnapshot.bytes } set { phaseSnapshot.bytes=newValue } }
    var phaseTotalBytes:Int64 { get { phaseSnapshot.total } set { phaseSnapshot.total=newValue } }
    @Published var isPreflighting=false
    @Published var verificationSchedule:VerificationSchedule = .afterCopy
    @Published var ioBufferSize:IOBufferSize = .automatic
    @Published var includeThumbnails=false
    private let ioQueue=DispatchQueue(label:"local.nefcopy.io",qos:.userInitiated)
    private var workerPhaseName="Ready"
    private var workerPhaseTotal:Int64 = -1
    private var activeBufferSize:IOBufferSize = .automatic
#if DEBUG
    var testBufferSelected:((String,Int)->Void)?
#endif
    private func bufferBytes(for file:URL,size:Int64)->Int {
        let bytes=activeBufferSize.bytes(forFileSize:size)
#if DEBUG
        testBufferSelected?(file.path,bytes)
#endif
        return bytes
    }
    private var measuredCopyBytes:Int64=0
    private var measuredVerifyBytes:Int64=0
    private var pipelineActive=false
    private var resumeSchedule:VerificationSchedule = .afterCopy
    private var resumeBuffer:IOBufferSize = .automatic
    private struct PendingVerification {
        let entry:CopyEntry
        let destination:Destination
        let target:URL
        let temp:URL
        let checksum:String
        let sourceModified:Double?
    }
    @Published var lastActivityAt=Date()
    private var phaseStarted=Date()
    private var phaseProcessed:Int64=0
    private var lastPhasePublish=Date.distantPast
    private var lastOverallPublish=Date.distantPast
    private var verificationWork:Int64=0
    private var plannedVerificationWork:Int64=0
    private var worker:DispatchWorkItem?
    private var workspaceObservers:[NSObjectProtocol]=[]
    private var disconnectMessage:String?
    private var sleepActivity: NSObjectProtocol?
    private struct FailedTransfer { let entry: CopyEntry; let destination: Destination; let retryable: Bool }
    private var failedTransfers:[FailedTransfer]=[]
    private var resumeSources:[URL]=[]
    private var resumeDestinations:[Destination]=[]
    private var resumeVerifyEnabled=true
    private var resumeTransferStrategy:TransferStrategy = .standard
    private enum RunMode { case normal, resume, retryFailed, retryDestinations }
    private struct ManifestEntry: Codable {
        let relativePath:String
        let sourceSize:Int64
        let sourceModified:Double
        let destinationSize:Int64
        let destinationModified:Double
        let checksum:String
        let verified:Bool
    }
    private struct ManifestFile: Codable { var version:Int = 2; var algorithm:String = "XXH64BE"; var entries:[ManifestEntry] = [] }
#if DEBUG
    // Deterministic fault/slow-copy hooks used only by XCTest debug builds.
    private static let isolatedXCTestHistory=FileManager.default.temporaryDirectory.appendingPathComponent("NefCopy-XCTest-History-"+UUID().uuidString,isDirectory:true)
    var testLocalHistoryDirectory:URL {historyDirectory()}
    var testAvailableBytes:Int64?
    var testSleepPreventionActive:Bool {sleepActivity != nil}
    var testFailCopyOncePaths:Set<String>=[]
    var testCopyDelayPerChunk:TimeInterval=0
    var testHashDelayPerChunk:TimeInterval=0
    var testSourceBytesRead:Int64=0
    var testManifestLoads=0
    var testDestinationWriteDelays:[String:TimeInterval]=[:]
    var testDestinationFailureBytes:[String:Int64]=[:]
    var testWriteDelayPerChunk:TimeInterval=0
    var testDestinationBeforeCopy:[String:(URL)->Void]=[:]
    var testBeforeCopy:((URL)->Void)?
    var testWriteFailureAfterBytes:Int64?
    private var testWrittenBytes:Int64=0
    func testDisconnectDestination(_ url:URL) { disconnectDestination(url) }
    func testDisconnectSource() { disconnectMessage="Source Disconnected: simulated";cancel() }

    var testVerificationDeviceKeys:[String:String]=[:]
    var testCorruptTempBeforeVerify=false
#endif
    var isRunning:Bool { isPreflighting || state == .copying || state == .verifying }
    var sourceName:String { sourceURLs.count == 1 ? sourceURLs[0].lastPathComponent : "\(sourceURLs.count) items" }

    init(writesHistory:Bool=true){
        self.writesHistory=writesHistory
        if writesHistory { loadHistory(); refreshMountedDrives() }
        let nc=NSWorkspace.shared.notificationCenter
        if writesHistory { workspaceObservers.append(nc.addObserver(forName:NSWorkspace.didUnmountNotification,object:nil,queue:.main){ [weak self] note in
            guard let self, self.isRunning, let volume=note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else{return}
            self.handleUnmountedVolume(volume)
        }) }
    }
    deinit {
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        destinationTimer?.cancel()
        stopSleepPrevention()
    }

    private func startSleepPrevention(){
        guard sleepActivity == nil else{return}
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: "NefCopy transfer in progress"
        )
    }
    private func stopSleepPrevention(){
        guard let token=sleepActivity else{return}
        ProcessInfo.processInfo.endActivity(token)
        sleepActivity=nil
    }

    private func volumeRoot(for url:URL)->URL? {
        let path=url.standardizedFileURL.path
        guard path.hasPrefix("/Volumes/") else{return nil}
        let parts=path.split(separator:"/")
        guard parts.count >= 2 else{return nil}
        return URL(fileURLWithPath:"/Volumes/" + String(parts[1]),isDirectory:true)
    }
    private func sameVolume(_ url:URL,_ volume:URL)->Bool {
        volumeRoot(for:url)?.standardizedFileURL == volume.standardizedFileURL
    }
    private func handleUnmountedVolume(_ volume:URL){
        if transferStrategy == .cascading && cascadeSourceReleased {
            if let primary=cascadePrimaryDestination,sameVolume(primary,volume) {
                cascadeDependencyFailure="Primary SSD disconnected during cascading."
                errorMessage=cascadeDependencyFailure;cancel();return
            }
            for d in destinations where sameVolume(d.url,volume) {disconnectDestination(d.url)}
            return
        }
        let sourceHit=sourceURLs.contains{ sameVolume($0,volume) } || resumeSources.contains{ sameVolume($0,volume) }
        let dest=(destinations + resumeDestinations).first{ sameVolume($0.url,volume) }
        guard sourceHit || dest != nil else{return}
        if !sourceHit, let dest, isolationPreparing || !destinationWorkers.isEmpty {
            for d in (destinations + resumeDestinations) where sameVolume(d.url,volume) { disconnectDestination(d.url) }
            return
        }
        let title=sourceHit ? "Source Disconnected" : "Destination Disconnected"
        let detail=sourceHit
            ? "The source drive was disconnected during transfer. NefCopy stopped the transfer."
            : "\(dest?.name ?? volume.lastPathComponent) was disconnected during transfer. NefCopy stopped the transfer and will not mark the offload as verified."
        disconnectMessage="\(title): \(detail)"
        errorMessage=detail
        statusText=title
        cancel()
    }

    func chooseSource(){
        let p=NSOpenPanel(); p.title="Choose Source Files or Folders"; p.canChooseFiles=true; p.canChooseDirectories=true; p.allowsMultipleSelection=true
        if p.runModal() == .OK { addSources(p.urls) }
    }
    func setSources(_ urls:[URL]){
        guard !isRunning else{return}; let clean=Array(Set(urls)).sorted{$0.path<$1.path}; guard !clean.isEmpty else{return}
        resetJobStatus(); sourceURLs=clean; statusText="Ready to copy"; scanSource()
    }
    func addSources(_ urls:[URL]) {
        guard !isRunning else{return}
        let combined = sourceURLs + urls
        setSources(combined)
    }
    func addDroppedSources(_ urls:[URL]) { addSources(urls) }
    func removeSource(_ url:URL){ guard !isRunning else{return}; resetJobStatus(); sourceURLs.removeAll{$0 == url}; scanSource(); if sourceURLs.isEmpty { statusText="Drop files/folders or choose a source" } }
    func clearSources(){ guard !isRunning else{return}; resetJobStatus(); sourceURLs=[]; totalFiles=0; totalBytes=0; statusText="Drop files/folders or choose a source" }
    private var sourceScanWork: DispatchWorkItem?
    private func scanSource(){
        sourceScanWork?.cancel()
        let snapshot = sourceURLs
        if snapshot.isEmpty { totalFiles=0; totalBytes=0; return }
        let work=DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let entries = try self.makeEntries(snapshot)
                let bytes = entries.reduce(Int64(0)) { $0 + $1.size }
                DispatchQueue.main.async {
                    guard self.sourceURLs == snapshot else { return }
                    self.totalFiles = entries.count
                    self.totalBytes = bytes
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.sourceURLs == snapshot else { return }
                    self.totalFiles = 0
                    self.totalBytes = 0
                    self.statusText = "Source scan failed: \(error.localizedDescription)"
                }
            }
        }
        sourceScanWork=work
        ioQueue.asyncAfter(deadline:.now()+0.2,execute:work)
    }
    func addDestination(){
        let p=NSOpenPanel(); p.title="Choose Destination"; p.canChooseFiles=false; p.canChooseDirectories=true; p.allowsMultipleSelection=true
        if p.runModal() == .OK { resetJobStatus(); for u in p.urls where !destinations.contains(where:{ $0.url == u }) { destinations.append(Destination(url:u)) } }
    }
    func removeDestination(_ d:Destination){ guard !isRunning else{return}; resetJobStatus(); destinations.removeAll{$0.id==d.id} }
    func clearDestinations(){ guard !isRunning else{return}; resetJobStatus(); destinations=[] }
    func addDestinationURL(_ u: URL){ guard !isRunning else{return}; if !destinations.contains(where:{ $0.url.standardizedFileURL == u.standardizedFileURL }) { resetJobStatus(); destinations.append(Destination(url:u)) } }
    func addSourceURL(_ u: URL){ addSources([u]) }
    private func filesystemCapacity(for url:URL)->(total:Int64, available:Int64)? {
#if DEBUG
        if let available=testAvailableBytes {return (max(1_000_000_000,available),available)}
#endif
        // FileManager's filesystem attributes are reliable for HFS+/APFS volumes and
        // large RAID volumes where URLResourceValues may report nil/zero capacity.
        guard let attrs=try? FileManager.default.attributesOfFileSystem(forPath:url.path),
              let totalNumber=attrs[.systemSize] as? NSNumber,
              let freeNumber=attrs[.systemFreeSize] as? NSNumber else { return nil }
        let total=totalNumber.int64Value
        let available=freeNumber.int64Value
        guard total > 0, available >= 0 else { return nil }
        return (total,available)
    }

    func refreshMountedDrives(){
        let keys:Set<URLResourceKey>=[.volumeNameKey,.volumeTotalCapacityKey,.volumeAvailableCapacityKey,.volumeAvailableCapacityForImportantUsageKey,.volumeIsReadOnlyKey]
        let urls=FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:Array(keys), options:[.skipHiddenVolumes]) ?? []
        let drives=urls.compactMap { u -> MountedDrive? in
            guard u.path == "/" || u.path.hasPrefix("/Volumes/") else { return nil }
            let v=try? u.resourceValues(forKeys:keys)
            let name=v?.volumeName ?? u.lastPathComponent

            // Prefer filesystem attributes. Fall back to URL resource values only
            // when the filesystem query is unavailable. Never turn an unknown
            // capacity into a misleading "Zero KB free".
            let fs=filesystemCapacity(for:u)
            let resourceTotal=Int64(v?.volumeTotalCapacity ?? 0)
            let resourceAvail:Int64
            if let available=v?.volumeAvailableCapacity {
                resourceAvail=Int64(available)
            } else if let important=v?.volumeAvailableCapacityForImportantUsage {
                resourceAvail=important
            } else {
                resourceAvail=0
            }
            let total=fs?.total ?? resourceTotal
            let avail=fs?.available ?? resourceAvail
            guard total > 0, avail >= 0 else { return nil }
            return MountedDrive(url:u,name:name,capacity:total,available:avail)
        }.sorted{$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending}
        DispatchQueue.main.async { self.mountedDrives=drives }
    }
    private func basicPreflight() -> PreflightResult {
        var messages:[String]=[]; var ok=true
        if ascMHLEnabled && !verifyEnabled {ok=false;messages.append("FAIL — ASC MHL requires checksum verification.")}
        if independentSourceVerification && !verifyEnabled {
            ok=false;messages.append("FAIL — Independent source verification requires destination checksum verification.")
        }
        if transferStrategy == .cascading {
            if !verifyEnabled {ok=false;messages.append("FAIL — Cascading requires checksum verification.")}
            if destinations.count<2 {ok=false;messages.append("FAIL — Cascading needs a primary SSD and another destination.")}
            if cascadePrimaryDestination == nil || !destinations.contains(where:{$0.url.standardizedFileURL == cascadePrimaryDestination?.standardizedFileURL}) {
                ok=false;messages.append("FAIL — Select a primary SSD from the destinations.")
            }
            let paths=destinations.map{$0.url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()}
            for i in paths.indices {
                for j in paths.indices where j>i {
                    if paths[i]==paths[j] || (paths[i]+"/").hasPrefix(paths[j]+"/") || (paths[j]+"/").hasPrefix(paths[i]+"/") {
                        ok=false;messages.append("FAIL — Cascading destination folders must not overlap.")
                    }
                }
            }
        }
        if sourceURLs.isEmpty { ok=false; messages.append("FAIL — No source selected") } else { messages.append("PASS — \(sourceURLs.count) source item(s), \(totalFiles) files") }
        if destinations.isEmpty { ok=false; messages.append("FAIL — No destination selected") }
        for d in destinations {
            let dp = d.url.standardizedFileURL.path.hasSuffix("/") ? d.url.standardizedFileURL.path : d.url.standardizedFileURL.path + "/"
            for s in sourceURLs {
                let sp0 = s.standardizedFileURL.path
                let sp = sp0.hasSuffix("/") ? sp0 : sp0 + "/"
                if sp0 == d.url.standardizedFileURL.path || dp.hasPrefix(sp) || sp.hasPrefix(dp) {
                    ok=false; messages.append("FAIL — Source and destination paths overlap: \(s.lastPathComponent) ↔ \(d.name)")
                }
            }
        }
        return PreflightResult(ok:ok,messages:messages)
    }

    func runPreflight(completion: @escaping (PreflightResult) -> Void) {
        guard !isRunning else { completion(PreflightResult(ok:false,messages:["FAIL — Another operation is still running"])); return }
        sourceScanWork?.cancel()
        isPreflighting=true
        let sources=sourceURLs, dests=destinations, verify=verifyEnabled
        let basicResult=basicPreflight()
        activeBufferSize=ioBufferSize
        cancelled=false
        DispatchQueue.main.async { self.preflightProgress=0; self.preflightStatus="Preparing scan…"; self.phaseName="Preparing scan"; self.phaseTotalBytes = -1 }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let result=basicResult; var messages=result.messages; var ok=result.ok
            guard ok else { DispatchQueue.main.async { self.isPreflighting=false; self.preflightProgress=1; self.preflightStatus="Pre-flight blocked"; completion(PreflightResult(ok:false,messages:messages)) }; return }
            do {
                let entries=try self.makeEntries(sources)
                try self.validateUniqueRelativePaths(entries)
                let totalChecks=max(entries.count * max(dests.count,1),1); var checked=0
                var lastScanPublish=Date.distantPast
                var identical=0, conflicts=0
                var manifests:[UUID:[String:ManifestEntry]]=[:]
                for d in dests { manifests[d.id]=self.loadManifest(for:d.url) }
                for d in dests {
                    // Preserve only fully checked entries even when the user cancels later.
                    defer { if let map=manifests[d.id] { try? self.saveManifest(map,for:d.url) } }
                    var required:Int64=0
                    let retained=self.ascMHLEnabled ? try ASCMHL.retainedArtifacts(entries:entries,destination:d.url):Set<String>()
                    for e in entries {
                        try self.pauseCheckpoint()
                        if retained.contains(e.source.path) {checked+=1;messages.append("SKIP — Preserved extended ASC history — \(e.relativePath)");continue}
                        let target=d.url.appendingPathComponent(e.relativePath)
                        if FileManager.default.fileExists(atPath:target.path) {
                            if let cached=manifests[d.id]?[e.relativePath], self.manifestEntry(cached, stillMatchesSource:e.source, destination:target) {
                                identical += 1; messages.append("SKIP — IDENTICAL (cached verified XXH64BE) — \(e.relativePath) @ \(d.name)")
                            } else {
                                let sh=try self.checksumHex(e.source), dh=try self.checksumHex(target)
                                if sh == dh {
                                    identical += 1; messages.append("SKIP — IDENTICAL — \(e.relativePath) @ \(d.name)")
                                    if let m=self.makeManifestEntry(relativePath:e.relativePath,source:e.source,destination:target,checksum:sh,verified:true) { manifests[d.id]?[e.relativePath]=m }
                                } else {
                                    conflicts += 1; ok=false
                                    messages.append("FAIL — CONFLICT — \(e.relativePath) @ \(d.name) — existing file is DIFFERENT and will NOT be overwritten")
                                }
                            }
                        } else { required += e.size }
                        checked += 1; let checkedSnapshot=checked; let fraction=Double(checked)/Double(totalChecks)
                        if checked == totalChecks || Date().timeIntervalSince(lastScanPublish) >= 0.1 {
                            lastScanPublish=Date()
                            DispatchQueue.main.async { self.preflightProgress=fraction; self.preflightStatus="Scanning \(checkedSnapshot)/\(totalChecks) — \(Int(fraction*100))%" }
                        }
                    }
                    if let free=self.freeSpace(for:d.url) {
                        if free < required { ok=false; messages.append("FAIL — \(d.name) needs \(ByteCountFormatter.string(fromByteCount:required,countStyle:.file)) for files that still need copying; only \(ByteCountFormatter.string(fromByteCount:free,countStyle:.file)) free") }
                        else { messages.append("PASS — \(d.name) has enough free space for remaining copies") }
                    } else { messages.append("WARNING — Could not read free space for \(d.name)") }
                }
                if identical == 0 && conflicts == 0 { messages.append("PASS — Duplicate Protection: no existing destination files") }
                else if conflicts == 0 { messages.append("PASS — Duplicate Protection: \(identical) identical existing file(s) will be skipped") }
                if verify { messages.append("PASS — XXH64BE verification enabled") } else { messages.append("WARNING — Final verification is OFF; Duplicate Protection still uses XXH64BE") }
            } catch { ok=false; messages.append("FAIL — Duplicate scan error: \(error.localizedDescription)") }
            DispatchQueue.main.async { self.isPreflighting=false; self.preflightProgress=1; self.preflightStatus = ok ? "Scan complete — 100%" : "Pre-flight blocked"; completion(PreflightResult(ok:ok,messages:messages)) }
        }
    }

    private func manifestURL(for destination:URL)->URL { destination.appendingPathComponent("NefCopy Reports",isDirectory:true).appendingPathComponent(".nefcopy_manifest.json") }
    private func fileMetadata(_ u:URL)->(Int64,Double)? {
        guard let a=try? FileManager.default.attributesOfItem(atPath:u.path), let n=a[.size] as? NSNumber, let d=a[.modificationDate] as? Date else{return nil}
        return (n.int64Value,d.timeIntervalSince1970)
    }
    private func makeManifestEntry(relativePath:String,source:URL,destination:URL,checksum:String,verified:Bool)->ManifestEntry? {
        guard let s=fileMetadata(source), let d=fileMetadata(destination) else{return nil}
        return ManifestEntry(relativePath:relativePath,sourceSize:s.0,sourceModified:s.1,destinationSize:d.0,destinationModified:d.1,checksum:checksum,verified:verified)
    }
    private func manifestEntry(_ m:ManifestEntry,stillMatchesSource source:URL,destination:URL)->Bool {
        guard !independentSourceVerification, m.verified, let s=fileMetadata(source), let d=fileMetadata(destination) else{return false}
        return s.0 == m.sourceSize && d.0 == m.destinationSize && abs(s.1-m.sourceModified)<0.01 && abs(d.1-m.destinationModified)<0.01
    }
    // Recovery must rehash published files rather than trust cached metadata.
    var revalidateExistingFiles=false
    var partialFileNamespace:String?
    private func partialURL(for target:URL)->URL {
        let tag=partialFileNamespace.map{$0+"-"} ?? ""
        return target.deletingLastPathComponent().appendingPathComponent(".nefcopy-partial-"+tag+UUID().uuidString)
    }
    // Direct filesystem calls avoid Foundation replacement directories when the
    // process is killed during creation/publication of a private staging file.
    private func createTemporaryFile(_ url:URL)throws {
        let fd=url.withUnsafeFileSystemRepresentation {path -> Int32 in
            guard let path else {return -1}
            return Darwin.open(path,O_WRONLY|O_CREAT|O_EXCL,mode_t(0o666))
        }
        guard fd>=0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        guard Darwin.close(fd)==0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    }
    private func discardTemporaryFile(_ url:URL)throws {
        let result=url.withUnsafeFileSystemRepresentation {path -> Int32 in
            guard let path else{return -1};return Darwin.unlink(path)
        }
        if result != 0 && errno != ENOENT {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    }
    private func publishTemporaryFile(_ temp:URL,to target:URL)throws {
        let result=temp.withUnsafeFileSystemRepresentation {source -> Int32 in
            target.withUnsafeFileSystemRepresentation {destination -> Int32 in
                guard let source,let destination else{return -1}
                return Darwin.renamex_np(source,destination,UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            let code=errno
            if code==EEXIST {throw CopyError.duplicateConflict(target.lastPathComponent)}
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
        }
    }
    private func cleanRecoveredPartials(entries:[CopyEntry],destinations:[Destination])throws {
        guard revalidateExistingFiles,let namespace=partialFileNamespace,UUID(uuidString:namespace) != nil else{return}
        let prefix=".nefcopy-partial-"+namespace+"-"
        for destination in destinations {
            try requireDestinationConnection(destination)
            let parents=Set(entries.map{destination.url.appendingPathComponent($0.relativePath).deletingLastPathComponent()})
            for parent in parents where FileManager.default.fileExists(atPath:parent.path) {
                let root=destination.url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                let resolved=parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                guard resolved.count>=root.count,Array(resolved.prefix(root.count))==root else {
                    throw CopyError.duplicateConflict("Staging folder escaped selected destination: \(parent.path)")
                }
                let children=try FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil)
                let legacyContainers=children.filter {
                    $0.lastPathComponent.hasPrefix("(A Document Being Saved") &&
                    (try? FileManager.default.attributesOfItem(atPath:$0.path)[.type] as? FileAttributeType) == .typeDirectory
                }
                for container in [parent]+legacyContainers {
                    var removedOwnedFile=false
                    for url in try FileManager.default.contentsOfDirectory(at:container,includingPropertiesForKeys:nil) where url.lastPathComponent.hasPrefix(prefix) {
                        let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
                        if attrs[.type] as? FileAttributeType == .typeRegular {
                            try discardTemporaryFile(url);removedOwnedFile=true
                        }
                    }
                    // Only an empty legacy container from which we removed our
                    // own UUID-tagged staging file may be removed; never recurse.
                    if container != parent && removedOwnedFile {
                        _=container.withUnsafeFileSystemRepresentation {path in path.map{Darwin.rmdir($0)} ?? -1}
                    }
                }
            }
        }
    }
    private func loadManifest(for destination:URL)->[String:ManifestEntry] {
        if revalidateExistingFiles || independentSourceVerification {return [:]}
#if DEBUG
        testManifestLoads += 1
#endif
        guard let data=try? Data(contentsOf:manifestURL(for:destination)), let f=try? JSONDecoder().decode(ManifestFile.self,from:data), f.version == 2, f.algorithm == "XXH64BE" else{return [:]}
        var entries:[String:ManifestEntry]=[:]
        for entry in f.entries {
            guard entries[entry.relativePath] == nil else { return [:] }
            entries[entry.relativePath]=entry
        }
        return entries
    }
    private func saveManifest(_ map:[String:ManifestEntry],for destination:URL)throws {
        let u=manifestURL(for:destination); try FileManager.default.createDirectory(at:u.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data=try JSONEncoder().encode(ManifestFile(entries:Array(map.values).sorted{$0.relativePath<$1.relativePath})); try data.write(to:u,options:.atomic)
    }
    private func updateVerifiedManifest(records:[ChecksumRecord],destination:URL) {
        var map=loadManifest(for:destination)
        for r in records where r.status == "PASS" && r.destination.hasPrefix(destination.path) && r.sourceChecksum != "Not verified" {
            let source=URL(fileURLWithPath:r.source), target=URL(fileURLWithPath:r.destination)
            if let m=makeManifestEntry(relativePath:r.file,source:source,destination:target,checksum:r.sourceChecksum,verified:true) { map[r.file]=m }
        }
        try? saveManifest(map,for:destination)
    }

    private func resetJobStatus(){
        destinationProgress=[];isolatedFailedDestinations=[]
        cancelled=false; phaseName="Ready"; phaseProgress=0; phaseBytes=0; phaseTotalBytes=0; state = .idle; progress=0; currentFile=""; speedBytesPerSecond=0; etaSeconds=0; overallEtaSeconds=0; copiedFileCount=0; pendingVerifyFileCount=0; elapsedSeconds=0; copyProcessingSeconds=0; verifyProcessingSeconds=0; copiedBytes=0; completedFiles=0; passCount=0; failCount=0; lastRunWasVerified=false; errorMessage=nil; lastReportURL=nil; failedTransfers=[]
    }
    func cancelPreflight(){ if isPreflighting { cancelled=true; preflightStatus="Cancelling pre-flight…" } }
    func pauseTransfer() {
        guard isRunning, !isPreflighting, !isPaused, (errorMessage == nil || !destinationWorkers.isEmpty), phaseName != "Writing reports", phaseName != "Finished" else { return }
        pauseCondition.lock(); pauseRequested=true; pauseCondition.unlock()
        isPaused=true
        for (_,child) in destinationWorkers where child.isRunning { child.pauseTransfer() }
        statusText="Stopped — Resume continues this job from the current position"
    }
    private func pauseCheckpoint() throws {
        pauseCondition.lock()
        while pauseRequested { pauseCondition.wait() }
        pauseCondition.unlock()
        if cancelled { throw CopyError.cancelled }
    }
    func cancel(){ cancelled=true; isPaused=false; statusText="Cancelling…"; for (_,child) in destinationWorkers where child.isRunning { child.cancel() } }
    func reveal(_ u:URL){ NSWorkspace.shared.activateFileViewerSelecting([u]) }
    func openReports(){
        if let report=lastReportURL, FileManager.default.fileExists(atPath:report.path) {
            NSWorkspace.shared.activateFileViewerSelecting([report])
        } else {
            for destination in destinations where FileManager.default.fileExists(atPath:destination.url.path) {
                NSWorkspace.shared.open(destination.url)
            }
        }
    }
    var canResume:Bool { isPaused || (!isRunning && (state == .cancelled || state == .failed) && !resumeSources.isEmpty && !resumeDestinations.isEmpty) }
    var canRetryFailed:Bool { !isRunning && (!isolatedFailedDestinations.isEmpty || failedTransfers.contains(where:{ $0.retryable })) }
    var canSafeEject:Bool { !isRunning && state == .completed && failCount == 0 && lastRunWasVerified && !lastRunWasPartialRetry }
    func resumeTransfer(){
        guard canResume else{return}
        if isPaused {
            isPaused=false
            statusText="Continuing current transfer…"
            pauseCondition.lock(); pauseRequested=false; pauseCondition.broadcast(); pauseCondition.unlock()
            for (_,child) in destinationWorkers where child.isPaused { child.resumeTransfer() }
            return
        }
        start(mode:.resume)
    }
    func retryFailed(){ guard canRetryFailed else{return}; start(mode:transferStrategy == .cascading ? .resume:(isolatedFailedDestinations.isEmpty ? .retryFailed:.retryDestinations)) }
    func ejectSources(){
        guard canSafeEject else{return}
        let volumes=sourceURLs.compactMap { u -> URL? in
            let comps=u.standardizedFileURL.pathComponents
            guard comps.count >= 3, comps[1] == "Volumes" else{return nil}
            return URL(fileURLWithPath:"/Volumes/"+comps[2],isDirectory:true)
        }
        for v in Array(Set(volumes)) { do { try NSWorkspace.shared.unmountAndEjectDevice(at:v) } catch { DispatchQueue.main.async { self.errorMessage="Could not eject \(v.lastPathComponent): \(error.localizedDescription)" } } }
    }
    func freeSpace(for u:URL)->Int64? {
        // Keep pre-flight and Start Transfer on the same RAID-safe capacity path.
        // Some large HFS+/RAID volumes report nil/zero via URLResourceValues even
        // though filesystem attributes report the correct available space.
        filesystemCapacity(for:u)?.available
    }

    func useRecommendedSettings() {
        guard !isRunning else { return }
        verificationSchedule = .afterCopy; ioBufferSize = .automatic
        transferStrategy = .singleReadFanOut; verifyEnabled=true; independentSourceVerification=false; includeThumbnails=false
    }
    private var ioReadSeconds:TimeInterval=0
    private var ioWriteSeconds:TimeInterval=0
    private var ioHashSeconds:TimeInterval=0
    private var ioSyncSeconds:TimeInterval=0
    private var copyStageFinishedAt:Date?
    private func measureIO<T>(_ kind:String,_ action:() throws -> T) rethrows -> T {
        let started=Date()
        defer {
            let seconds=Date().timeIntervalSince(started)
            switch kind {
            case "read": ioReadSeconds += seconds
            case "write": ioWriteSeconds += seconds
            case "hash": ioHashSeconds += seconds
            default: ioSyncSeconds += seconds
            }
        }
        return try action()
    }
    func start(){ start(mode:.normal) }

    private func start(mode:RunMode){
        guard !isRunning else{return}
        sourceReadMetrics.reset();completedSourceReadBytes=0;ascMHLManifestPaths=[]
        if writesHistory {
            ascMHLOperationStart=Date()
            expectedSourceHashes=[:];independentSourceReadMetrics.reset()
            independentSourceVerifiedFiles=0;sourceReferenceOrigin="None";sourceReferenceBytes=0;sourceReferenceFileCount=0
        }
        cascadeSourceReleased=false;cascadeSourceReleasedAt=nil
        cascadeOriginalReadBytes=0;cascadeReplicaReadBytes=0;cascadeDependencyFailure=nil
        verifiedContentHashes=[:]
        if writesHistory {sharedSourceReads=nil;completedSharedReadStatistics=nil}
        lastRunWasPartialRetry = mode == .retryDestinations
        pauseCondition.lock(); pauseRequested=false; pauseCondition.broadcast(); pauseCondition.unlock()
        isPaused=false
        if mode != .resume && mode != .retryDestinations {
            guard !sourceURLs.isEmpty,!destinations.isEmpty else{return}
            let check=basicPreflight(); guard check.ok else { errorMessage=check.messages.filter{$0.hasPrefix("FAIL")}.joined(separator:" • "); statusText="Pre-flight failed"; return }
        }
        let retryItems = failedTransfers.filter{$0.retryable}
        if mode == .retryFailed && retryItems.isEmpty { return }
        if mode == .normal { resumeSources=sourceURLs; resumeDestinations=destinations; resumeVerifyEnabled=verifyEnabled; resumeASCMHL=ascMHLEnabled; resumeIndependentSourceVerification=independentSourceVerification; resumeTransferStrategy=transferStrategy; resumeSchedule=verificationSchedule; resumeBuffer=ioBufferSize }
        let recovery = mode == .resume || mode == .retryDestinations
        let runSources = recovery ? resumeSources : sourceURLs
        let runDestinations = mode == .retryDestinations ? isolatedFailedDestinations : (recovery ? resumeDestinations : destinations)
        let runVerify = recovery ? resumeVerifyEnabled : verifyEnabled
        let sourceVerify = recovery ? resumeIndependentSourceVerification : independentSourceVerification
        independentSourceVerification=sourceVerify
        ascMHLEnabled=recovery ? resumeASCMHL:ascMHLEnabled
        let runStrategy = recovery ? resumeTransferStrategy : transferStrategy
        let runSchedule = recovery ? resumeSchedule : verificationSchedule
        pipelineActive=runVerify && runSchedule == .pipelined
        activeBufferSize=recovery ? resumeBuffer : ioBufferSize
        guard !runSources.isEmpty, !runDestinations.isEmpty else { return }

        ioReadSeconds=0; ioWriteSeconds=0; ioHashSeconds=0; ioSyncSeconds=0; copyStageFinishedAt=nil; plannedFilesByDestination=[:]; plannedBytesByDestination=[:]; plannedReportEntries=[:]; attemptedReportTargets=[]; pendingReportHashes=[:]; elapsedSeconds=0; copyProcessingSeconds=0; verifyProcessingSeconds=0; copiedFileCount=0; pendingVerifyFileCount=0
        verificationWork=0; plannedVerificationWork=0; measuredTransferBytes=0; measuredCopyBytes=0; measuredVerifyBytes=0; measuredCopySeconds=0; measuredVerifySeconds=0; overallEtaSeconds=0;
        phaseName="Preparing / checking destinations"; phaseTotalBytes = -1; phaseProgress=0; lastActivityAt=Date()
        startSleepPrevention()
        disconnectMessage=nil; cancelled=false; errorMessage=nil; copiedBytes=0; completedFiles=0; passCount=0; failCount=0; lastRunWasVerified=false; progress=0; speedBytesPerSecond=0; etaSeconds=0; state = .copying; statusText = mode == .retryFailed ? "Retrying failed files…" : (mode == .resume ? "Resuming transfer…" : "Scanning source…"); lastReportURL=nil
        if mode != .retryFailed { failedTransfers=[] }
        let sources=runSources, dests=runDestinations, verify=runVerify, strategy=runStrategy
        reportSourceNames=[]; reportSourceURLs=sources; reportSourceNames=(strategy == .cascading && cascadeCheckpoint != nil) ? sources.map{$0.lastPathComponent}:folderNames(sources)
        if writesHistory && strategy == .cascading {
            startCascading(sources:sources,dests:dests,schedule:runSchedule,buffer:recovery ? resumeBuffer:ioBufferSize,sourceVerify:sourceVerify)
            return
        }
        if writesHistory && ((strategy == .singleReadFanOut && dests.count>1) || mode == .retryDestinations) {
            startIsolatedDestinations(sources:sources,dests:dests,verify:verify,schedule:runSchedule,buffer:recovery ? resumeBuffer:ioBufferSize,sourceVerify:sourceVerify)
            return
        }
        destinationProgress=[]; isolatedFailedDestinations=[]
        destinationDeviceIDs=[:]
        let work=DispatchWorkItem{[weak self] in guard let self else{return}; let startedAt=Date(); var records:[ChecksumRecord]=[]; var newFailures:[FailedTransfer]=[]
            var pending:[PendingVerification]=[]
            let pipeline = BoundedVerifier(sharedBudget:!self.writesHistory)
            var verificationKeys:[UUID:String]=[:]
            for d in dests {
                var key=BoundedVerifier.deviceKey(for:d.url)
#if DEBUG
                key=self.testVerificationDeviceKeys[d.url.standardizedFileURL.path] ?? key
#endif
                verificationKeys[d.id]=key
            }
            let parallelAfterCopy=verify && runSchedule == .afterCopy && Set(verificationKeys.values).count>1 && !verificationKeys.values.contains("unknown-storage")
            var parallelVerificationPhase=false
            func collectPipelineProgress() {
                let sample=pipeline.takeProgress()
                self.verificationWork += sample.bytes; self.measuredVerifyBytes += sample.bytes
                self.measuredTransferBytes += sample.bytes; self.measuredVerifySeconds += sample.seconds
                if parallelVerificationPhase { self.advancePhase(sample.bytes) }
            }
            func enqueue(_ item:PendingVerification) throws {
                pending.append(item)
                self.pendingReportHashes[item.target.path]=item.checksum
                DispatchQueue.main.async { self.pendingVerifyFileCount += 1 }
                if runSchedule == .pipelined {
                    var corrupt=false
#if DEBUG
                    corrupt=self.testCorruptTempBeforeVerify; self.testCorruptTempBeforeVerify=false
#endif
                    try pipeline.submit(item.temp,buffer:self.bufferBytes(for:item.temp,size:item.entry.size),corrupt:corrupt,isCancelled:{ self.cancelled },
                                        deviceKey:verificationKeys[item.destination.id],checkpoint:{ try self.pauseCheckpoint() })
                }
            }
            defer { pipeline.waitForAll(); for item in pending { try? self.discardTemporaryFile(item.temp) } }

            do {
                let rawEntries=try self.preparedEntries ?? self.makeEntries(sources)
                var retained=Set<String>()
                if self.ascMHLEnabled && dests.count==1 {retained=try ASCMHL.retainedArtifacts(entries:rawEntries,destination:dests[0].url)}
                let allEntries=rawEntries.filter{!retained.contains($0.source.path)}
                try self.validateUniqueRelativePaths(allEntries)
                if self.writesHistory && sourceVerify {try self.verifySourcesIndependently(allEntries)}

                let jobs:[(CopyEntry,Destination)] = mode == .retryFailed ? retryItems.map{($0.entry,$0.destination)} : dests.flatMap { d in allEntries.map { ($0,d) } }
                self.plannedReportEntries=Dictionary(grouping:jobs,by:{$0.1.url.standardizedFileURL.path}).mapValues{$0.map{$0.0}}
                self.plannedFilesByDestination=Dictionary(grouping:jobs,by:{$0.1.url.standardizedFileURL.path}).mapValues{$0.count}
                self.plannedBytesByDestination=Dictionary(grouping:jobs,by:{$0.1.url.standardizedFileURL.path}).mapValues{$0.reduce(Int64(0)){$0+$1.0.size}}
                try self.cleanRecoveredPartials(entries:allEntries,destinations:dests)
                // Check every run, including Resume/Retry, before creating any copies.
                for d in dests {
                    try self.requireDestinationConnection(d)
                    let required=jobs.filter { $0.1.id == d.id }.reduce(Int64(0)) { total, job in
                        FileManager.default.fileExists(atPath:d.url.appendingPathComponent(job.0.relativePath).path) ? total : total + job.0.size
                    }
                    guard let capacity=self.filesystemCapacity(for:d.url) else { throw CopyError.freeSpaceUnavailable(d.name) }
                    if capacity.available < required {
                        throw CopyError.insufficientSpace(d.name,required,capacity.available,
                            ByteCountFormatter.string(fromByteCount:required,countStyle:.file),
                            ByteCountFormatter.string(fromByteCount:capacity.available,countStyle:.file))
                    }
                }
                // One manifest snapshot per destination for this run. Each cached
                // entry still has its source/destination metadata revalidated.
                var runManifests:[UUID:[String:ManifestEntry]]=[:]
                for d in dests { runManifests[d.id]=self.loadManifest(for:d.url) }
                if mode != .retryFailed { try self.validateNoConflicts(entries:allEntries, destinations:dests, manifests:&runManifests) }
                let grand=jobs.reduce(Int64(0)){$0+$1.0.size}
                self.verificationWork=0; self.plannedVerificationWork=verify ? grand : 0
                self.lastOverallPublish=Date.distantPast; self.transferClockStarted=Date()
                DispatchQueue.main.async{ self.totalFiles=jobs.count; self.totalBytes=grand; self.statusText = mode == .retryFailed ? "Retrying failed files only…" : (mode == .resume ? "Resuming — checking completed files…" : "Copying…") }
                var done:Int64=0
                if strategy == .singleReadFanOut && mode != .retryFailed && dests.count > 1 {
                    // Fan-out mode: each source file is opened once and each chunk is written to every
                    // destination temp file before the next source chunk is read.
                    for e in allEntries {
                        try self.pauseCheckpoint()
                        DispatchQueue.main.async { self.state = .copying; self.currentFile=e.relativePath; self.statusText="Single-read fan-out → \(dests.count) destinations" }
                        var active:[(Destination,URL,URL,FileHandle)] = []
                        defer { for item in active {
                            try? item.3.close()
                            if !pending.contains(where: { $0.temp == item.2 }) { try? self.discardTemporaryFile(item.2) }
                        } }
                        var skipped:[(Destination,URL,String)] = []
                        for d in dests {
                            let target=d.url.appendingPathComponent(e.relativePath)
                            self.attemptedReportTargets.insert(target.path)
                            let temp=self.partialURL(for:target)
                            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                            if FileManager.default.fileExists(atPath:target.path) {
                                let cached=runManifests[d.id]?[e.relativePath]
                                let sh:String, dh:String
                                if let cached, self.manifestEntry(cached,stillMatchesSource:e.source,destination:target) { sh=cached.checksum; dh=cached.checksum }
                                else { sh=try self.checksumHex(e.source); dh=try self.checksumHex(target) }
                                if sh == dh { DispatchQueue.main.async { self.copiedFileCount += 1 }; skipped.append((d,target,sh)); done += e.size; if verify { self.verificationWork += e.size }; collectPipelineProgress(); self.publishProgress(done,grand,startedAt); continue }
                                throw CopyError.duplicateConflict(e.relativePath)
                            }
                            try self.createTemporaryFile(temp)
                            active.append((d,target,temp,try FileHandle(forWritingTo:temp)))
                        }
                        for (_,target,hash) in skipped {
                            records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:target.path,sourceChecksum:hash,destinationChecksum:hash,status:"PASS"))
                            DispatchQueue.main.async { self.completedFiles += 1; self.passCount += 1 }
                        }
                        // Duplicate validation above already established all skipped
                        // results. No destination needs bytes: do not open/read/hash
                        // the source again just to submit to an empty writer list.
                        guard !active.isEmpty else { continue }
                        let sourceMetadataBefore=self.fileMetadata(e.source)
                        self.beginPhase("Copying",total:e.size)
                        let sourceHasher=XXH64BE()
                        let fanout=BoundedFanoutWriter(handles:active.map { $0.3 },maxChunksInFlight:4)
                        let fileBufferBytes=self.bufferBytes(for:e.source,size:e.size)
                        do {
                            let input=try FileHandle(forReadingFrom:e.source); defer { try? input.close() }
                            while true {
                                try self.pauseCheckpoint()
                                let data=try measureIO("read") { try autoreleasepool { try input.read(upToCount:fileBufferBytes) ?? Data() } }
                                if data.isEmpty { break }
                                if verify { self.measureIO("hash") { sourceHasher.update(data:data) } }
                                self.advancePhase(Int64(data.count))
                                try fanout.submit(data, isCancelled: { self.cancelled })
#if DEBUG
                                self.testSourceBytesRead += Int64(data.count)
#endif
                                let delta=Int64(data.count) * Int64(active.count)
                                done += delta; self.measuredTransferBytes += delta; self.measuredCopyBytes += delta; collectPipelineProgress(); self.publishProgress(done,grand,startedAt)
#if DEBUG
                                if self.testCopyDelayPerChunk > 0 { Thread.sleep(forTimeInterval:self.testCopyDelayPerChunk) }
#endif
                            }
                            try fanout.finish()
                            for item in active { try self.measureIO("sync") { try item.3.synchronize() }; try item.3.close() }
                        } catch {
                            for item in active { try? item.3.close(); try? self.discardTemporaryFile(item.2) }
                            throw error
                        }
                        if verify {
                            guard let before=sourceMetadataBefore, let after=self.fileMetadata(e.source), before.0 == after.0,
                                  before.1 == after.1, self.phaseProcessed == before.0 else {
                                throw CopyError.verifyFailed("Source changed during copy: " + e.relativePath)
                            }
                        }
                        self.publishProgress(done,grand,startedAt,force:true)
                        self.measuredCopySeconds += Date().timeIntervalSince(self.phaseStarted)
                        self.advancePhase(0,force:true)
                        DispatchQueue.main.async { self.copiedFileCount += active.count }
                        let sourceHash = verify ? sourceHasher.finalize().map{String(format:"%02x",$0)}.joined() : "Not verified"
                        if let expected=self.expectedSourceHashes[e.source.path],sourceHash != expected {
                            throw CopyError.verifyFailed("Source checksum differs from independent pre-read: "+e.relativePath)
                        }
                        for (d,target,temp,_) in active {
                            do {
                                var destinationHash="Not verified"
                                if verify && runSchedule != .perFile {
                                    try enqueue(PendingVerification(entry:e,destination:d,target:target,temp:temp,checksum:sourceHash,sourceModified:self.fileMetadata(e.source)?.1))
                                    continue
                                }
                                if verify {
                                    DispatchQueue.main.async { self.state = .verifying; self.statusText="Verifying \(e.relativePath) on \(d.name)" }
                                    destinationHash=try self.checksumHex(temp,phase:"Verifying destination") { delta in
                                        self.verificationWork += delta; self.measuredTransferBytes += delta; self.measuredVerifyBytes += delta
                                        collectPipelineProgress(); self.publishProgress(done,grand,startedAt)
                                    }
                                    guard sourceHash == destinationHash else { throw CopyError.verifyFailed(e.relativePath) }
                                }
                                if FileManager.default.fileExists(atPath:target.path) { throw CopyError.duplicateConflict(e.relativePath) }
                                try self.publishTemporaryFile(temp,to:target)
                                records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:target.path,sourceChecksum:sourceHash,destinationChecksum:destinationHash,status:verify ? "PASS":"COPIED"))
                                DispatchQueue.main.async { self.completedFiles += 1; self.passCount += 1 }
                            } catch CopyError.cancelled {
                                throw CopyError.cancelled
                            } catch {
                                try? self.discardTemporaryFile(temp)
                                newFailures.append(FailedTransfer(entry:e,destination:d,retryable:true))
                                records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:target.path,sourceChecksum:sourceHash,destinationChecksum:"ERROR",status:"FAIL"))
                                DispatchQueue.main.async { self.completedFiles += 1; self.failCount += 1; self.errorMessage="\(e.relativePath) on \(d.name): \(error.localizedDescription)" }
                            }
                        }
                    }
                } else {
                for (e,d) in jobs {
                    let jobStartDone = done
                    try self.pauseCheckpoint()
                    let target=d.url.appendingPathComponent(e.relativePath)
                    self.attemptedReportTargets.insert(target.path)
                    let temp=self.partialURL(for:target)
                    DispatchQueue.main.async{ self.state = .copying; self.currentFile=e.relativePath; self.statusText=runSchedule == .pipelined && verify ? "Copying + verifying in background" : "Copying to \(d.name)" }
                    do {
                        try self.requireDestinationConnection(d)
                        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                        var sourceHash="Not verified", destinationHash="Not verified"
                        if FileManager.default.fileExists(atPath:target.path) {
                            DispatchQueue.main.async{ self.state = .verifying; self.statusText="Duplicate Protection — checking \(e.relativePath)" }
                            let cached=runManifests[d.id]?[e.relativePath]
                            if let cached, self.manifestEntry(cached,stillMatchesSource:e.source,destination:target) { sourceHash=cached.checksum; destinationHash=cached.checksum }
                            else { sourceHash=try self.checksumHex(e.source); destinationHash=try self.checksumHex(target) }
                            if sourceHash == destinationHash {
                                DispatchQueue.main.async { self.copiedFileCount += 1 }
                                done += e.size; if verify { self.verificationWork += e.size }; collectPipelineProgress(); self.publishProgress(done,grand,startedAt)
                                records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:target.path,sourceChecksum:sourceHash,destinationChecksum:destinationHash,status:"PASS"))
                                DispatchQueue.main.async{ self.completedFiles += 1; self.passCount += 1 }
                                continue
                            }
                            records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:target.path,sourceChecksum:sourceHash,destinationChecksum:destinationHash,status:"FAIL"))
                            newFailures.append(FailedTransfer(entry:e,destination:d,retryable:false)); done += e.size; collectPipelineProgress(); self.publishProgress(done,grand,startedAt)
                            DispatchQueue.main.async{ self.completedFiles += 1; self.failCount += 1; self.errorMessage="Duplicate conflict: \(e.relativePath) already exists and is different. Existing file was NOT overwritten." }
                            continue
                        }
                        sourceHash=try self.copyFile(e.source,to:temp,hashSource:verify,expectedSize:e.size){ delta in done += delta; self.measuredTransferBytes += delta; self.measuredCopyBytes += delta; collectPipelineProgress(); self.publishProgress(done,grand,startedAt) }
                        DispatchQueue.main.async { self.copiedFileCount += 1 }
                        self.publishProgress(done,grand,startedAt,force:true)
                        if verify && runSchedule != .perFile {
                            try enqueue(PendingVerification(entry:e,destination:d,target:target,temp:temp,checksum:sourceHash,sourceModified:self.fileMetadata(e.source)?.1))
                            continue
                        }
                        if verify {
                            DispatchQueue.main.async{ self.state = .verifying; self.statusText="Verifying \(e.relativePath)" }
                            destinationHash=try self.checksumHex(temp,phase:"Verifying destination") { delta in
                                self.verificationWork += delta; self.measuredTransferBytes += delta; self.measuredVerifyBytes += delta
                                collectPipelineProgress(); self.publishProgress(done,grand,startedAt)
                            }
                            if sourceHash != destinationHash {
                                try? self.discardTemporaryFile(temp)
                                records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:target.path,sourceChecksum:sourceHash,destinationChecksum:destinationHash,status:"FAIL"))
                                newFailures.append(FailedTransfer(entry:e,destination:d,retryable:true))
                                DispatchQueue.main.async{ self.completedFiles += 1; self.failCount += 1 }
                                continue
                            }
                        }
                        // Atomic publish: a partial copy never appears under the final filename.
                        if FileManager.default.fileExists(atPath:target.path) { throw CopyError.duplicateConflict(e.relativePath) }
                        try self.publishTemporaryFile(temp,to:target)
                        if !verify { sourceHash="Not verified"; destinationHash="Not verified" }
                        records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:target.path,sourceChecksum:sourceHash,destinationChecksum:destinationHash,status: verify ? "PASS" : "COPIED"))
                        DispatchQueue.main.async{ self.completedFiles += 1; self.passCount += 1 }
                    } catch CopyError.cancelled {
                        try? self.discardTemporaryFile(temp); throw CopyError.cancelled
                    } catch {
                        try? self.discardTemporaryFile(temp)
                        newFailures.append(FailedTransfer(entry:e,destination:d,retryable:true)); done = min(grand, jobStartDone + e.size); collectPipelineProgress(); self.publishProgress(done,grand,startedAt)
                        records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:target.path,sourceChecksum:"ERROR",destinationChecksum:"ERROR",status:"FAIL"))
                        DispatchQueue.main.async{ self.completedFiles += 1; self.failCount += 1; self.errorMessage="\(e.relativePath): \(error.localizedDescription)" }
                    }
                }
                }
                self.publishProgress(done,grand,startedAt,force:true)
                self.copyStageFinishedAt=Date()
                if parallelAfterCopy {
                    parallelVerificationPhase=true
                    self.beginPhase("Verifying destinations",total:pending.reduce(Int64(0)) { $0+$1.entry.size })
                    DispatchQueue.main.async { self.state = .verifying; self.statusText="Verifying destinations concurrently" }
#if DEBUG
                    pipeline.testDelayPerChunk=self.testHashDelayPerChunk
#endif
                    for item in pending {
                        try self.pauseCheckpoint()
                        var corrupt=false
#if DEBUG
                        corrupt=self.testCorruptTempBeforeVerify; self.testCorruptTempBeforeVerify=false
#endif
                        try pipeline.submit(item.temp,buffer:self.bufferBytes(for:item.temp,size:item.entry.size),corrupt:corrupt,isCancelled:{ self.cancelled },
                                            deviceKey:verificationKeys[item.destination.id],bounded:false,
                                            checkpoint:{ try self.pauseCheckpoint() })
                    }
                }
                for item in pending {
                    try self.pauseCheckpoint()
                    let e=item.entry, d=item.destination
                    defer { DispatchQueue.main.async { self.pendingVerifyFileCount=max(0,self.pendingVerifyFileCount-1) } }
                    DispatchQueue.main.async { self.state = .verifying; self.currentFile=e.relativePath; self.statusText="Verifying copied files on \(d.name)" }
                    do {
                        guard let expectedModified=item.sourceModified,
                              let metadata=self.fileMetadata(e.source), metadata.0 == e.size,
                              metadata.1 == expectedModified else { throw CopyError.verifyFailed("Source changed before verification: " + e.relativePath) }
#if DEBUG
                        if runSchedule != .pipelined && !parallelAfterCopy && self.testCorruptTempBeforeVerify {
                            self.testCorruptTempBeforeVerify=false
                            let corrupt=try FileHandle(forWritingTo:item.temp)
                            try corrupt.write(contentsOf:Data([0x00])); try corrupt.close()
                        }
#endif
                        let hash:String
                        if runSchedule == .pipelined || parallelAfterCopy {
                            if !parallelAfterCopy { self.beginPhase("Waiting for destination verification",total:-1) }
                            hash=try pipeline.result(for:item.temp) {
                                collectPipelineProgress(); self.publishProgress(done,grand,startedAt)
                            }
                            collectPipelineProgress(); self.publishProgress(done,grand,startedAt,force:true)
                        } else {
                            hash=try self.checksumHex(item.temp,phase:"Verifying destination") { delta in
                                self.verificationWork += delta; self.measuredTransferBytes += delta; self.measuredVerifyBytes += delta
                                self.publishProgress(done,grand,startedAt)
                            }
                        }
                        guard hash == item.checksum else { throw CopyError.verifyFailed(e.relativePath) }
                        try self.pauseCheckpoint()
                        guard !FileManager.default.fileExists(atPath:item.target.path) else { throw CopyError.duplicateConflict(e.relativePath) }
                        try self.publishTemporaryFile(item.temp,to:item.target)
                        records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:item.target.path,sourceChecksum:item.checksum,destinationChecksum:hash,status:"PASS"))
                        DispatchQueue.main.async { self.completedFiles += 1; self.passCount += 1 }
                    } catch CopyError.cancelled { throw CopyError.cancelled }
                    catch {
                        try? self.discardTemporaryFile(item.temp)
                        newFailures.append(FailedTransfer(entry:e,destination:d,retryable:true))
                        records.append(ChecksumRecord(file:e.relativePath,source:e.source.path,destination:item.target.path,sourceChecksum:item.checksum,destinationChecksum:"ERROR",status:"FAIL"))
                        DispatchQueue.main.async { self.completedFiles += 1; self.failCount += 1; self.errorMessage=error.localizedDescription }
                    }
                }
                let failures=records.filter{$0.status == "FAIL"}.count
                let passes=records.filter{$0.status == "PASS"}.count
                let copiedOnly=records.filter{$0.status == "COPIED"}.count
                let successes=passes + copiedOnly
                let finalStatus = failures == 0 ? (verify ? "COMPLETED / VERIFIED" : "COMPLETED / NOT VERIFIED") : "COMPLETED WITH FAILURES"
                DispatchQueue.main.async { self.phaseName="Writing reports"; self.phaseTotalBytes = -1; self.phaseProgress=0; self.speedBytesPerSecond=0; self.etaSeconds=0;self.overallEtaSeconds=0; self.statusText="Writing reports…" }
                let report=try self.writeReports(records:records,started:startedAt,status:finalStatus,bytes:grand,files:jobs.count,verified:verify,sources:sources,destinations:dests.map{$0.url})
                let finishedFailures=newFailures
                DispatchQueue.main.async{ self.isPaused=false; self.failedTransfers=finishedFailures; self.elapsedSeconds=Date().timeIntervalSince(startedAt); self.pendingVerifyFileCount=0; self.stopSleepPrevention(); self.lastReportURL=report; self.phaseName="Finished"; self.phaseProgress=1; self.progress=1; self.state = failures == 0 ? .completed : .failed; self.currentFile=""; self.speedBytesPerSecond=0; self.etaSeconds=0;self.overallEtaSeconds=0; self.passCount=successes; self.failCount=failures; self.lastRunWasVerified = verify && failures == 0; self.statusText=failures == 0 ? (verify ? "VERIFIED — \(passes) PASS / 0 FAIL" : "COPIED — \(copiedOnly) file(s) / NOT VERIFIED") : "Finished — \(successes) successful / \(failures) FAIL."; self.loadHistory() }
            } catch CopyError.cancelled {
                pipeline.waitForAll()
                let terminalReport=try? self.writeReports(records:records,started:startedAt,status:"CANCELLED",bytes:self.copiedBytes,files:self.completedFiles,verified:verify,sources:sources,destinations:dests.map{$0.url})
                for item in pending { try? self.discardTemporaryFile(item.temp) }
                let cancelledFailures=newFailures
                DispatchQueue.main.async{
                    self.failedTransfers=cancelledFailures
                    self.lastReportURL=terminalReport
                    self.elapsedSeconds=Date().timeIntervalSince(startedAt)
                    self.stopSleepPrevention()
                    self.isPaused=false; self.state = .cancelled; self.pendingVerifyFileCount=0
                    if let disconnect=self.disconnectMessage {
                        self.statusText=disconnect
                    } else {
                        self.statusText="Transfer cancelled — Resume Transfer will skip files already completed and restart only the interrupted file"
                    }
                    self.currentFile="";self.speedBytesPerSecond=0;self.etaSeconds=0;self.overallEtaSeconds=0;self.loadHistory()
                }
            } catch {
                pipeline.waitForAll()
                for item in pending { try? self.discardTemporaryFile(item.temp) }
                let terminalReport=try? self.writeReports(records:records,started:startedAt,status:"FAILED: \(error.localizedDescription)",bytes:self.copiedBytes,files:self.completedFiles,verified:verify,sources:sources,destinations:dests.map{$0.url})
                let fatalFailures=newFailures
                DispatchQueue.main.async{self.lastReportURL=terminalReport;self.elapsedSeconds=Date().timeIntervalSince(startedAt);self.failedTransfers=fatalFailures;self.pendingVerifyFileCount=0;self.stopSleepPrevention();self.isPaused=false;self.state = .failed;self.statusText="Transfer failed — Resume Transfer is available";self.errorMessage=error.localizedDescription;self.currentFile="";self.speedBytesPerSecond=0;self.etaSeconds=0;self.overallEtaSeconds=0;self.loadHistory()}
            }
        }; worker=work; ioQueue.async(execute:work)
    }

    private func validateUniqueRelativePaths(_ entries:[CopyEntry]) throws {
        var seen:[String:String]=[:]
        for e in entries {
            let key=e.relativePath.precomposedStringWithCanonicalMapping.lowercased()
            if let prior=seen[key], prior != e.source.path {
                throw CopyError.duplicateConflict("Source name collision: \(e.relativePath) comes from more than one source")
            }
            seen[key]=e.source.path
        }
    }

    private func validateNoConflicts(entries:[CopyEntry], destinations:[Destination], manifests:inout [UUID:[String:ManifestEntry]]) throws {
        for d in destinations {
            var manifest=manifests[d.id] ?? [:]
            let retained=ascMHLEnabled ? try ASCMHL.retainedArtifacts(entries:entries,destination:d.url):Set<String>()
            for e in entries {
                if retained.contains(e.source.path) {continue}
                try pauseCheckpoint()
                let target=d.url.appendingPathComponent(e.relativePath)
                guard FileManager.default.fileExists(atPath:target.path) else { continue }
                if let cached=manifest[e.relativePath], manifestEntry(cached,stillMatchesSource:e.source,destination:target) { continue }
                let sh=try checksumHex(e.source), dh=try checksumHex(target)
                if sh != dh { throw CopyError.duplicateConflict("\(e.relativePath) @ \(d.name)") }
                if let m=makeManifestEntry(relativePath:e.relativePath,source:e.source,destination:target,checksum:sh,verified:true) { manifest[e.relativePath]=m }
            }
            manifests[d.id]=manifest
            try? saveManifest(manifest,for:d.url)
        }
    }

    // Both URLs are canonicalized by the inventory builder. Cache the selected
    // root's components once per enumeration; still check every child's resolved
    // components so a symlink/path escape cannot enter a transfer manifest.
    private func relativeChildPath(_ child:URL, rootComponents:[String]) throws -> String {
        let cp=child.pathComponents
        guard cp.count > rootComponents.count, cp.starts(with:rootComponents) else {
            throw CopyError.duplicateConflict("Source enumeration escaped selected folder: \(child.path)")
        }
        return cp.dropFirst(rootComponents.count).joined(separator:"/")
    }

    private func makeEntries(_ sources:[URL]) throws->[CopyEntry]{ var out:[CopyEntry]=[]
        for originalRoot in sources {
            try pauseCheckpoint()
            let root=originalRoot.standardizedFileURL.resolvingSymlinksInPath()
            let v=try root.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.fileSizeKey])
            if v.isRegularFile == true { out.append(CopyEntry(source:root,relativePath:root.lastPathComponent,size:Int64(v.fileSize ?? 0))); continue }
            guard v.isDirectory == true else{continue}
            let rootComponents=root.pathComponents, rootName=root.lastPathComponent
            let keys:Set<URLResourceKey>=[.isRegularFileKey,.fileSizeKey,.isSymbolicLinkKey]
            guard let en=FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys),options:[.skipsHiddenFiles,.skipsPackageDescendants]) else{continue}
            while let originalChild=en.nextObject() as? URL {
                try pauseCheckpoint()
                let x=try originalChild.resourceValues(forKeys:keys)
                guard x.isRegularFile==true,x.isSymbolicLink != true else{continue}
                let child=originalChild.standardizedFileURL.resolvingSymlinksInPath()
                let rel=try relativeChildPath(child,rootComponents:rootComponents)
                out.append(CopyEntry(source:child,relativePath:rootName+"/"+rel,size:Int64(x.fileSize ?? 0)))
            }
        }
        if ascMHLEnabled && !destinations.isEmpty {
            var common:Set<String>?
            for destination in destinations {
                let retained=try ASCMHL.retainedArtifacts(entries:out,destination:destination.url)
                common=common.map{$0.intersection(retained)} ?? retained
            }
            out.removeAll{common?.contains($0.source.path)==true}
        }
        return out }
    private func beginPhase(_ name:String,total:Int64) {
        workerPhaseName=name; workerPhaseTotal=total
        phaseStarted=Date(); phaseProcessed=0; lastPhasePublish=Date.distantPast
        let snapshot=PhaseSnapshot(name:name,progress:0,bytes:0,total:total)
        DispatchQueue.main.async {
            self.phaseSnapshot=snapshot; self.speedBytesPerSecond=0; self.etaSeconds=0
        }
    }
    private func advancePhase(_ delta:Int64,force:Bool=false) {
        phaseProcessed += delta
        let now=Date()
        guard force || now.timeIntervalSince(lastPhasePublish)>=0.1 else { return }
        lastPhasePublish=now
        let processed=phaseProcessed, total=workerPhaseTotal
        let elapsed=max(now.timeIntervalSince(phaseStarted),0.001)
        let speed=Double(processed)/elapsed
        let snapshot=PhaseSnapshot(name:workerPhaseName,progress:total>0 ? min(1,Double(processed)/Double(total)) : (total == 0 ? 1 : 0),bytes:processed,total:total)
        let remaining=speed>0 && total>=0 ? Double(max(0,total-processed))/speed : 0
        DispatchQueue.main.async {
            self.phaseSnapshot=snapshot; self.speedBytesPerSecond=speed; self.etaSeconds=remaining; self.lastActivityAt=now
        }
    }
    private func copyFile(_ s:URL,to d:URL,hashSource:Bool,expectedSize:Int64,progress:(Int64)->Void)throws->String {
#if DEBUG
        if testFailCopyOncePaths.remove(s.path) != nil { throw CocoaError(.fileWriteUnknown) }
#endif
#if DEBUG
        testBeforeCopy?(s)
#endif
        let initialMetadata=fileMetadata(s)
        if let expected=preparedSourceMetadata[s.path] {
            guard let actual=initialMetadata,actual.0==expected.0,actual.1==expected.1 else {
                throw CopyError.verifyFailed("Source changed since job planning: " + s.lastPathComponent)
            }
        }
        let size=expectedSize
        let fileBufferBytes=bufferBytes(for:s,size:size)
        beginPhase("Copying",total:size)
        let input=try FileHandle(forReadingFrom:s)
        defer { try? input.close() }
        try createTemporaryFile(d)
        let output=try FileHandle(forWritingTo:d)
        defer { try? output.close() }
        let hasher=XXH64BE()
        var sourceOffset:UInt64=0
        while true {
            try pauseCheckpoint()
            let load:() throws->Data = {
                let chunk=try self.measureIO("read") {
                    if self.sharedSourceReads != nil {try input.seek(toOffset:sourceOffset)}
                    return try autoreleasepool {try input.read(upToCount:fileBufferBytes) ?? Data()}
                }
                self.sourceReadMetrics.add(chunk.count)
                return chunk
            }
            let data:Data
            if let sharedSourceReads {
                data=try sharedSourceReads.read(source:s,offset:sourceOffset,count:fileBufferBytes,checkpoint:{try self.pauseCheckpoint()},load:load)
            } else {data=try load()}
            sourceOffset+=UInt64(data.count)
            if data.isEmpty { break }
            if hashSource { measureIO("hash") { hasher.update(data:data) } }
#if DEBUG
            if let limit=testWriteFailureAfterBytes, testWrittenBytes>=limit { throw NSError(domain:NSPOSIXErrorDomain,code:19) }
            if testWriteDelayPerChunk>0 { Thread.sleep(forTimeInterval:testWriteDelayPerChunk) }
#endif
            try measureIO("write") { try autoreleasepool { try output.write(contentsOf:data) } }
#if DEBUG
            testWrittenBytes += Int64(data.count)
#endif
            let count=Int64(data.count)
            advancePhase(count); progress(count)
#if DEBUG
            testSourceBytesRead += count
            if testCopyDelayPerChunk>0 { Thread.sleep(forTimeInterval:testCopyDelayPerChunk) }
#endif
        }
        try measureIO("sync") { try output.synchronize() }
        if hashSource {
            guard let before=initialMetadata, let after=fileMetadata(s), before.0 == after.0, before.1 == after.1,
                  phaseProcessed == before.0 else { throw CopyError.verifyFailed("Source changed during copy: " + s.lastPathComponent) }
        }
        measuredCopySeconds += Date().timeIntervalSince(phaseStarted)
        advancePhase(0,force:true)
        let hash=hashSource ? hasher.finalize().map { String(format:"%02x",$0) }.joined():"Not verified"
        if let expected=expectedSourceHashes[s.path],hash != expected {
            throw CopyError.verifyFailed("Source checksum differs from verified reference: "+s.lastPathComponent)
        }
        return hash
    }
    // One independent pass for the entire job, before any copy worker starts.
    // This handle bypasses SharedSourceReadCache. Hashes are rechecked during
    // copying and for existing files; no successful preflight hash is persisted
    // as proof of a future run. A new run/recovered queue makes new references.
    private func verifySourcesIndependently(_ entries:[CopyEntry]) throws {
        DispatchQueue.main.async { self.statusText="Reading source independently before copying" }
        var references:[String:String]=[:]
        var totalRead:Int64=0
        for entry in entries {
            try pauseCheckpoint()
            guard let before=fileMetadata(entry.source),before.0==entry.size else {
                throw CopyError.verifyFailed("Source changed before independent verification: "+entry.relativePath)
            }
            var read:Int64=0
            let hash=try checksumHex(entry.source,phase:"Verifying source independently") { bytes in
                read+=bytes;self.independentSourceReadMetrics.add(Int(bytes))
            }
            guard let after=fileMetadata(entry.source),before.0==after.0,before.1==after.1,read==entry.size else {
                throw CopyError.verifyFailed("Source changed during independent verification: "+entry.relativePath)
            }
            references[entry.source.path]=hash;totalRead+=read
        }
        try pauseCheckpoint()
        expectedSourceHashes=references
        sourceReferenceOrigin="Original source independent pre-read"
        sourceReferenceBytes=totalRead;sourceReferenceFileCount=entries.count
        DispatchQueue.main.async {self.independentSourceVerifiedFiles=entries.count}
#if DEBUG
        try testAfterIndependentSourceVerification?()
#endif
    }

    private func checksumHex(_ u:URL,phase:String="Checking existing file",onChunk:((Int64)->Void)?=nil)throws->String {
        var release:(() -> Void)?
        if phase == "Verifying destination" && !writesHistory {
            release=try VerificationReadBudget.acquire(key:verificationLaneKey,checkpoint:{try self.pauseCheckpoint()})
        }
        defer {release?()}
        guard let metadata=fileMetadata(u) else { throw CocoaError(.fileReadUnknown) }
        beginPhase(phase,total:metadata.0)
        let fileBufferBytes=bufferBytes(for:u,size:metadata.0)
        let handle=try FileHandle(forReadingFrom:u)
        defer { try? handle.close() }
        let hasher=XXH64BE()
        while true {
            try pauseCheckpoint()
            let data=try measureIO("read") { try autoreleasepool { try handle.read(upToCount:fileBufferBytes) ?? Data() } }
            if data.isEmpty { break }
            measureIO("hash") { hasher.update(data:data) }
            advancePhase(Int64(data.count)); onChunk?(Int64(data.count))
#if DEBUG
            if testHashDelayPerChunk>0 { Thread.sleep(forTimeInterval:testHashDelayPerChunk) }
#endif
        }
        if phase == "Verifying destination" { measuredVerifySeconds += Date().timeIntervalSince(phaseStarted) }
        advancePhase(0,force:true)
        let hash=hasher.finalize().map { String(format:"%02x",$0) }.joined()
        if let expected=expectedSourceHashes[u.path],hash != expected {
            throw CopyError.verifyFailed("Source checksum differs from verified reference: "+u.lastPathComponent)
        }
        return hash
    }
    private func publishProgress(_ done:Int64,_ total:Int64,_ started:Date,force:Bool=false) {
        let now=Date()
        guard force || now.timeIntervalSince(lastOverallPublish)>=0.1 else { return }
        lastOverallPublish=now
        let work=Double(done)+Double(verificationWork)
        let budget=Double(total)+Double(plannedVerificationWork)
        let fraction=budget>0 ? min(0.999,work/budget) : 0
        // Average actual copy + verification bytes. Skipped files advance work
        // completion but never count as measured I/O throughput.
        let currentElapsed=max(now.timeIntervalSince(phaseStarted),0.001)
        let copyTime=measuredCopySeconds + (workerPhaseName == "Copying" ? currentElapsed : 0)
        let verifyTime=measuredVerifySeconds + (workerPhaseName == "Verifying destination" ? currentElapsed : 0)
        let copyRate=copyTime>0 ? Double(measuredCopyBytes)/copyTime : 0
        let verifyRate=verifyTime>0 ? Double(measuredVerifyBytes)/verifyTime : copyRate
        let remainingCopy=max(0,Double(total-done)), remainingVerify=max(0,Double(plannedVerificationWork-verificationWork))
        let copyRemaining=copyRate>0 ? remainingCopy/copyRate : 0
        let verifyRemaining=verifyRate>0 ? remainingVerify/verifyRate : 0
        let remainingSeconds=pipelineActive ? max(copyRemaining,verifyRemaining) : copyRemaining+verifyRemaining
        DispatchQueue.main.async {
            self.copiedBytes=done; self.progress=max(self.progress,fraction)
            self.elapsedSeconds=now.timeIntervalSince(started); self.copyProcessingSeconds=copyTime; self.verifyProcessingSeconds=verifyTime
            self.overallEtaSeconds=remainingSeconds.isFinite ? remainingSeconds : 0
        }
    }
    private func requireDestinationConnection(_ d:Destination) throws {
        guard let attributes=try? FileManager.default.attributesOfItem(atPath:d.url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileNoSuchFile) }
        if let number=attributes[.systemNumber] as? NSNumber {
            let current=number.uint64Value
            if let expected=destinationDeviceIDs[d.id], expected != current { throw CocoaError(.fileNoSuchFile) }
            destinationDeviceIDs[d.id]=current
        }
    }

    // Multi-drive isolation uses an independent existing copy/verification engine
    // per destination. A slow/blocking write never holds another writer's slots.
    // The explicit cost is one source read per destination instead of shared fan-out.
    private func disconnectDestination(_ url:URL) {
        if transferStrategy == .cascading && cascadePrimaryDestination?.standardizedFileURL == url.standardizedFileURL {
            cascadeDependencyFailure="Primary SSD disconnected during cascading."
            errorMessage=cascadeDependencyFailure;cancel();return
        }
        guard let (_,child)=destinationWorkers.first(where:{$0.0.url.standardizedFileURL == url.standardizedFileURL}) else {
            if isolationPreparing {disconnectedDestinationPaths.insert(url.standardizedFileURL.path)}
            statusText="Destination disconnected — other destinations will continue"
            return
        }
        guard child.isRunning else{return}
        disconnectedDestinationPaths.insert(url.standardizedFileURL.path)
        child.disconnectMessage="Destination Disconnected: \(url.lastPathComponent)"
        child.errorMessage="Destination disconnected; other destinations continue"
        child.cancel()
    }

    private func startIsolatedDestinations(sources:[URL],dests:[Destination],verify:Bool,schedule:VerificationSchedule,buffer:IOBufferSize,sourceVerify:Bool) {
        sharedSourceReads=SharedSourceReadCache()
#if DEBUG
        if testDisableSharedSourceReads {sharedSourceReads=nil}
#endif
        isolationPreparing=true; isolatedFailedDestinations=[]; destinationWorkers=[];disconnectedDestinationPaths=[]
        destinationProgress=dests.map{DestinationProgress(id:$0.id,name:$0.name,path:$0.url.path,progress:0,state:"Preparing",verified:false,report:nil)}
        let started=Date()
        ioQueue.async { [weak self] in
            guard let self else{return}
            do {
                let entries=try self.makeEntries(sources)
                try self.validateUniqueRelativePaths(entries)
                var sourceSnapshot:[String:(Int64,Double)]=[:]
                for entry in entries {
                    guard let metadata=self.fileMetadata(entry.source),metadata.0==entry.size else {throw CopyError.verifyFailed("Source changed during job planning: "+entry.relativePath)}
                    sourceSnapshot[entry.source.path]=metadata
                }
                if sourceVerify {try self.verifySourcesIndependently(entries)}
                // Preserve the existing all-destination duplicate-conflict guard.
                // An unavailable destination is instead left for its own worker.
                for d in dests {
                    try self.pauseCheckpoint()
                    guard FileManager.default.fileExists(atPath:d.url.path) else{continue}
                    var manifests=[d.id:self.loadManifest(for:d.url)]
                    do { try self.validateNoConflicts(entries:entries,destinations:[d],manifests:&manifests) }
                    catch let error as CopyError {
                        switch error { case .duplicateConflict,.cancelled:throw error; default:break }
                    } catch { /* Its destination worker will report the I/O failure. */ }
                }
                DispatchQueue.main.async {
                    self.isolationPreparing=false
                    if self.cancelled {
                        self.state = .cancelled;self.statusText="Transfer cancelled";self.stopSleepPrevention();return
                    }
                    self.totalFiles=entries.count*dests.count
                    self.totalBytes=entries.reduce(Int64(0)){$0+$1.size}*Int64(dests.count)
                    for (index,d) in dests.enumerated() {
                        let child=CopyEngine(writesHistory:false)
                        child.sourceURLs=sources;child.destinations=[d];child.preparedEntries=entries
                        child.preparedSourceMetadata=sourceSnapshot
                        child.expectedSourceHashes=self.expectedSourceHashes
                        child.independentSourceVerification=sourceVerify
                        child.ascMHLEnabled=self.ascMHLEnabled
                        child.ascMHLOperationStart=self.ascMHLOperationStart
                        child.independentSourceVerifiedFiles=self.independentSourceVerifiedFiles
                        child.sourceReferenceOrigin=self.sourceReferenceOrigin
                        child.sourceReferenceBytes=self.sourceReferenceBytes
                        child.sourceReferenceFileCount=self.sourceReferenceFileCount
                        child.sharedSourceReads=self.sharedSourceReads
                        child.revalidateExistingFiles=self.revalidateExistingFiles
                        child.partialFileNamespace=self.partialFileNamespace
                        child.verifyEnabled=verify;child.transferStrategy = .standard
                        child.verificationSchedule=schedule;child.ioBufferSize=buffer
                        child.verificationLaneKey=BoundedVerifier.deviceKey(for:d.url)
#if DEBUG
                        child.testCopyDelayPerChunk=self.testCopyDelayPerChunk
                        child.testHashDelayPerChunk=self.testHashDelayPerChunk
                        child.testFailCopyOncePaths=self.testFailCopyOncePaths
                        child.testBeforeCopy=self.testDestinationBeforeCopy[d.url.standardizedFileURL.path]
                        child.testWriteDelayPerChunk=self.testDestinationWriteDelays[d.url.standardizedFileURL.path] ?? 0
                        child.testWriteFailureAfterBytes=self.testDestinationFailureBytes[d.url.standardizedFileURL.path]
                        child.testCorruptTempBeforeVerify=index == 0 && self.testCorruptTempBeforeVerify
#endif
                        self.destinationWorkers.append((d,child))
                        child.start()
                        if self.disconnectedDestinationPaths.contains(d.url.standardizedFileURL.path) {self.disconnectDestination(d.url)}
                        if self.isPaused {child.pauseTransfer()}
                    }
#if DEBUG
                    self.testCorruptTempBeforeVerify=false
                    let planningManifestLoads=self.testManifestLoads
#endif
                    let timer=DispatchSource.makeTimerSource(queue:.main)
                    self.destinationTimer=timer
                    timer.schedule(deadline:.now(),repeating:.milliseconds(20))
                    timer.setEventHandler { [weak self] in
                        guard let self else{return}
                        let workers=self.destinationWorkers
                        guard !workers.isEmpty else{return}
                        self.destinationProgress=workers.map { d,c in
                            let disconnected=self.disconnectedDestinationPaths.contains(d.url.standardizedFileURL.path)
                            let label=disconnected ? "Disconnected":c.state == .completed ? (c.lastRunWasVerified ? "Verified":"Copied — not verified") : (c.disconnectMessage != nil ? "Disconnected":c.state.rawValue)
                            return DestinationProgress(id:d.id,name:d.name,path:d.url.path,progress:c.progress,state:label,verified:c.lastRunWasVerified && !disconnected,report:c.lastReportURL)
                        }
                        self.copiedBytes=workers.reduce(0){$0+$1.1.copiedBytes}
                        if workers.allSatisfy({$0.1.totalFiles>0}) {
                            self.totalFiles=workers.reduce(0){$0+$1.1.totalFiles};self.totalBytes=workers.reduce(0){$0+$1.1.totalBytes}
                        }
                        self.completedFiles=workers.reduce(0){$0+$1.1.completedFiles}
                        self.copiedFileCount=workers.reduce(0){$0+$1.1.copiedFileCount}
                        self.pendingVerifyFileCount=workers.reduce(0){$0+$1.1.pendingVerifyFileCount}
                        self.passCount=workers.reduce(0){$0+$1.1.passCount}
                        self.failCount=workers.reduce(0){$0+$1.1.failCount}
                        self.progress=min(0.999,workers.reduce(0){$0+$1.1.progress}/Double(workers.count))
                        self.phaseSnapshot=PhaseSnapshot(name:workers.contains(where:{$0.1.state == .verifying}) ? "Verifying destination":"Copying",progress:self.progress,bytes:workers.reduce(0){$0+$1.1.phaseBytes},total:workers.reduce(0){$0+max(0,$1.1.phaseTotalBytes)})
                        self.elapsedSeconds=Date().timeIntervalSince(started)
                        self.copyProcessingSeconds=workers.map{$0.1.copyProcessingSeconds}.max() ?? 0
                        self.verifyProcessingSeconds=workers.map{$0.1.verifyProcessingSeconds}.max() ?? 0
                        self.speedBytesPerSecond=workers.filter{$0.1.isRunning}.reduce(0){$0+$1.1.speedBytesPerSecond}
                        self.overallEtaSeconds=workers.filter{$0.1.isRunning}.map{$0.1.overallEtaSeconds}.max() ?? 0
                        self.currentFile=workers.first(where:{$0.1.isRunning})?.1.currentFile ?? ""
                        self.lastActivityAt=Date()
#if DEBUG
                        self.testSourceBytesRead=workers.reduce(0){$0+$1.1.testSourceBytesRead}
                        self.testManifestLoads=planningManifestLoads+workers.reduce(0){$0+$1.1.testManifestLoads}
#endif
                        let active=workers.filter{$0.1.isRunning}
                        let failed=workers.filter{!$0.1.isRunning && ($0.1.state != .completed || self.disconnectedDestinationPaths.contains($0.0.url.standardizedFileURL.path))}
                        if !failed.isEmpty {self.errorMessage="\(failed.count) destination(s) stopped; remaining destinations continue"}
                        if !active.isEmpty {
                            self.state=active.contains(where:{$0.1.state == .copying}) ? .copying:.verifying
                            if !self.isPaused {self.statusText="\(workers.count-active.count) finished · \(active.count) destination(s) working independently"}
                            return
                        }
                        self.destinationTimer?.cancel();self.destinationTimer=nil
                        self.failedTransfers=workers.flatMap{$0.1.failedTransfers}
                        self.isolatedFailedDestinations=failed.map{$0.0}
                        let allCompleted=failed.isEmpty
                        self.failCount=max(self.failCount,failed.count)
                        self.lastRunWasVerified=verify && allCompleted && workers.allSatisfy{$0.1.lastRunWasVerified}
                        self.lastReportURL=workers.compactMap{$0.1.lastReportURL}.first
                        self.state=self.cancelled ? .cancelled:(allCompleted ? .completed:.failed)
                        self.progress=1;self.phaseProgress=1;self.phaseName="Finished";self.isPaused=false
                        self.statusText=self.cancelled ? (self.disconnectMessage ?? "Transfer cancelled"):(allCompleted ? (verify ? (self.lastRunWasPartialRetry ? "VERIFIED — retried destinations passed":"VERIFIED — all destinations passed"):"COPIED — NOT VERIFIED") : "Finished with warnings — \(workers.count-failed.count) destination(s) completed, \(failed.count) stopped")
                        self.speedBytesPerSecond=0;self.etaSeconds=0;self.overallEtaSeconds=0
                        self.stopSleepPrevention()
                        do {
                            let dir=self.historyDirectory();try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                            var history=self.readHistory()
                            history.insert(TransferHistoryRecord(id:UUID(),date:started,sources:sources.map{$0.path},destinations:dests.map{$0.url.path},bytes:self.totalBytes,files:self.totalFiles,verified:self.lastRunWasVerified,status:self.statusText,reportPath:self.lastReportURL?.path),at:0)
                            try JSONEncoder().encode(Array(history.prefix(200))).write(to:dir.appendingPathComponent("history.json"),options:.atomic)
                            self.loadHistory()
                        } catch {self.errorMessage="Transfer logs exist, but local history could not be saved: \(error.localizedDescription)"}
                        self.completedSourceReadBytes=workers.reduce(0){$0+$1.1.sourceReadMetrics.readBytes}
                        self.completedSharedReadStatistics=self.sharedSourceReads?.statistics
                        self.sharedSourceReads=nil
                        self.destinationWorkers=[]
                    }
                    timer.resume()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isolationPreparing=false;self.state=self.cancelled ? .cancelled:.failed
                    self.errorMessage=error.localizedDescription;self.statusText="Pre-flight blocked";self.stopSleepPrevention()
                }
            }
        }
    }

    // The primary worker first creates verified replicas. Secondary workers keep
    // original relative paths and must match the primary's original-source hashes.
    private func cascadeChild(sources:[URL],destination:Destination,entries:[CopyEntry],metadata:[String:(Int64,Double)],hashes:[String:String],schedule:VerificationSchedule,buffer:IOBufferSize,cache:SharedSourceReadCache?)->CopyEngine {
        let child=CopyEngine(writesHistory:false)
        child.sourceURLs=sources;child.destinations=[destination]
        child.preparedEntries=entries;child.preparedSourceMetadata=metadata
        child.expectedSourceHashes=hashes;child.revalidateExistingFiles=true
        child.independentSourceVerification=self.independentSourceVerification
        child.ascMHLEnabled=self.ascMHLEnabled
        child.ascMHLOperationStart=self.ascMHLOperationStart
        child.independentSourceVerifiedFiles=self.independentSourceVerifiedFiles
        child.sourceReferenceOrigin=self.sourceReferenceOrigin == "None" && !hashes.isEmpty ? "Verified SSD checkpoint (original-source checksum)":self.sourceReferenceOrigin
        child.sourceReferenceBytes=self.sourceReferenceBytes
        child.sourceReferenceFileCount=self.sourceReferenceFileCount
        child.partialFileNamespace=partialFileNamespace
        child.verifyEnabled=true;child.transferStrategy = .standard
        child.verificationSchedule=schedule;child.ioBufferSize=buffer
        child.verificationLaneKey=BoundedVerifier.deviceKey(for:destination.url)
        child.sharedSourceReads=cache
#if DEBUG
        child.testCopyDelayPerChunk=testCopyDelayPerChunk
        child.testHashDelayPerChunk=testHashDelayPerChunk
        child.testWriteDelayPerChunk=testDestinationWriteDelays[destination.url.standardizedFileURL.path] ?? 0
        child.testWriteFailureAfterBytes=testDestinationFailureBytes[destination.url.standardizedFileURL.path]
        child.testBeforeCopy=testDestinationBeforeCopy[destination.url.standardizedFileURL.path]
        child.testCorruptTempBeforeVerify=testCascadeCorruptPrimary && hashes.isEmpty
#endif
        return child
    }

    private func startCascading(sources:[URL],dests:[Destination],schedule:VerificationSchedule,buffer:IOBufferSize,sourceVerify:Bool) {
        guard let primary=dests.first(where:{$0.url.standardizedFileURL==cascadePrimaryDestination?.standardizedFileURL}),dests.count>=2 else {
            state = .failed;errorMessage="Select a primary SSD and at least one secondary destination.";stopSleepPrevention();return
        }
        isolationPreparing=true;destinationWorkers=[];disconnectedDestinationPaths=[];destinationDeviceIDs=[:]
        destinationProgress=dests.map{DestinationProgress(id:$0.id,name:$0.name,path:$0.url.path,progress:0,state:$0.id==primary.id ? "Preparing primary SSD":"Waiting for verified SSD",verified:false,report:nil)}
        let started=Date()
        ioQueue.async { [weak self] in
            guard let self else{return}
            do {
                let recovery=self.cascadeCheckpoint
                let entries:[CopyEntry]
                var metadata:[String:(Int64,Double)]=[:]
                var recoveredHashes:[String:String]=[:]
                try self.requireDestinationConnection(primary)
                if let recovery {
                    try recovery.validate(sources:sources,destinations:dests.map{$0.url},primary:primary.url)
                    guard let volume=VolumeIdentity(url:primary.url),recovery.primaryVolume.matches(volume) else {
                        throw CopyError.verifyFailed("The original primary SSD is missing or has changed.")
                    }
                    let root=primary.url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                    var recoveredEntries:[CopyEntry]=[]
                    // Rehash every planned primary file before any secondary starts.
                    // Neither original sources nor unrelated SSD files are scanned.
                    for file in recovery.files {
                        try self.pauseCheckpoint()
                        let url=primary.url.appendingPathComponent(file.relativePath)
                        let resolved=url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                        guard resolved.count>root.count,Array(resolved.prefix(root.count))==root,
                              let attrs=try? FileManager.default.attributesOfItem(atPath:url.path),attrs[.type] as? FileAttributeType == .typeRegular,
                              let before=self.fileMetadata(url),before.0==file.size else {
                            throw CopyError.verifyFailed("Saved SSD file is missing or changed: "+file.relativePath)
                        }
                        let hash=try self.checksumHex(url,phase:"Validating saved SSD checkpoint")
                        guard hash==file.checksum,let after=self.fileMetadata(url),after.0==before.0,after.1==before.1 else {
                            throw CopyError.verifyFailed("Saved SSD checksum does not match original source: "+file.relativePath)
                        }
                        recoveredEntries.append(CopyEntry(source:url,relativePath:file.relativePath,size:file.size))
                        metadata[url.path]=after;recoveredHashes[url.path]=hash
                    }
                    entries=recoveredEntries
                } else {
                    entries=try self.makeEntries(sources)
                    for entry in entries {
                        guard let value=self.fileMetadata(entry.source),value.0==entry.size else {throw CopyError.verifyFailed("Source changed during cascade planning")}
                        metadata[entry.source.path]=value
                    }
                }
                try self.validateUniqueRelativePaths(entries)
                if recovery == nil && sourceVerify {try self.verifySourcesIndependently(entries)}
                let snapshot=metadata,validatedHashes=recoveredHashes
                DispatchQueue.main.async {
                    self.isolationPreparing=false
                    guard !self.cancelled else {self.state = .cancelled;self.stopSleepPrevention();return}
                    self.totalFiles=entries.count*dests.count
                    self.totalBytes=entries.reduce(Int64(0)){$0+$1.size}*Int64(dests.count)
                    let primaryWorker=self.cascadeChild(sources:sources,destination:primary,entries:entries,metadata:snapshot,hashes:self.expectedSourceHashes,schedule:schedule,buffer:buffer,cache:nil)
                    self.destinationWorkers=[(primary,primaryWorker)]
                    if let recovery {
                        // A completed primary placeholder represents the full rehash
                        // above; it never opens the original source or copies again.
                        primaryWorker.verifiedContentHashes=validatedHashes
                        primaryWorker.lastRunWasVerified=true;primaryWorker.state = .completed
                        primaryWorker.progress=1;primaryWorker.completedFiles=entries.count
                        primaryWorker.passCount=entries.count;primaryWorker.totalFiles=entries.count
                        primaryWorker.totalBytes=entries.reduce(Int64(0)){$0+$1.size}
                        primaryWorker.copiedBytes=primaryWorker.totalBytes
                        primaryWorker.lastReportURL=recovery.primaryReport
                    } else {
                        primaryWorker.start()
                        if self.isPaused {primaryWorker.pauseTransfer()}
                    }
                    var forwarded=false,preparingForward=false
                    let timer=DispatchSource.makeTimerSource(queue:.main)
                    self.destinationTimer=timer
                    timer.schedule(deadline:.now(),repeating:.milliseconds(20))
                    timer.setEventHandler { [weak self] in
                        guard let self else{return}
                        let workers=self.destinationWorkers
                        self.cascadeOriginalReadBytes=primaryWorker.sourceReadBytes
                        self.cascadeReplicaReadBytes=workers.filter{$0.0.id != primary.id}.reduce(0){$0+$1.1.sourceReadBytes}
                        self.copiedBytes=workers.reduce(0){$0+$1.1.copiedBytes}
                        self.completedFiles=workers.reduce(0){$0+$1.1.completedFiles}
                        self.copiedFileCount=workers.reduce(0){$0+$1.1.copiedFileCount}
                        self.pendingVerifyFileCount=workers.reduce(0){$0+$1.1.pendingVerifyFileCount}
                        self.passCount=workers.reduce(0){$0+$1.1.passCount}
                        self.failCount=workers.reduce(0){$0+$1.1.failCount}
                        self.progress=min(0.999,workers.reduce(0){$0+$1.1.progress}/Double(dests.count))
                        self.elapsedSeconds=Date().timeIntervalSince(started)
                        self.speedBytesPerSecond=workers.filter{$0.1.isRunning}.reduce(0){$0+$1.1.speedBytesPerSecond}
                        self.currentFile=workers.first(where:{$0.1.isRunning})?.1.currentFile ?? ""
                        self.phaseName=forwarded ? "Cascading from verified SSD":"Copying and verifying primary SSD"
                        if !self.isPaused {self.statusText=forwarded ? "Original source no longer needed for this job · distributing from SSD":"Verifying primary SSD before distributing"}
                        self.destinationProgress=dests.map { d in
                            guard let worker=workers.first(where:{$0.0.id==d.id})?.1 else {
                                return DestinationProgress(id:d.id,name:d.name,path:d.url.path,progress:0,state:"Waiting for verified SSD",verified:false,report:nil)
                            }
                            let disconnected=self.disconnectedDestinationPaths.contains(d.url.standardizedFileURL.path)
                            return DestinationProgress(id:d.id,name:d.name,path:d.url.path,progress:worker.progress,state:disconnected ? "Disconnected":worker.state.rawValue,verified:worker.lastRunWasVerified && !disconnected,report:worker.lastReportURL)
                        }
                        if !primaryWorker.isRunning && !forwarded && !preparingForward && primaryWorker.lastRunWasVerified && !self.cancelled {
                            preparingForward=true
#if DEBUG
                            self.testCascadeBeforeForward?(primary.url)
#endif
                            // Inspect only the planned replicas, never enumerate the SSD
                            // as a source (which would copy reports/unrelated files).
                            self.ioQueue.async {
                                do {
                                    try self.requireDestinationConnection(primary)
                                    var replicas:[CopyEntry]=[],replicaMetadata:[String:(Int64,Double)]=[:],hashes:[String:String]=[:]
                                    let root=primary.url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                                    for entry in entries {
                                        try self.pauseCheckpoint()
                                        if self.ascMHLEnabled && entry.relativePath.components(separatedBy:"/").contains("ascmhl") {continue}
                                        let url=primary.url.appendingPathComponent(entry.relativePath)
                                        let resolved=url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                                        guard resolved.count>root.count,Array(resolved.prefix(root.count))==root,
                                              let attrs=try? FileManager.default.attributesOfItem(atPath:url.path),attrs[.type] as? FileAttributeType == .typeRegular,
                                              let value=self.fileMetadata(url),value.0==entry.size,
                                              let hash=primaryWorker.verifiedContentHashes[url.path] else {throw CopyError.verifyFailed("Primary SSD replica missing or changed: "+entry.relativePath)}
                                        replicas.append(CopyEntry(source:url,relativePath:entry.relativePath,size:entry.size))
                                        replicaMetadata[url.path]=value;hashes[url.path]=hash
                                    }
                                    if self.ascMHLEnabled {
                                        // ASC chains legitimately change when the verified primary
                                        // extends its history. Forward its validated current artifacts,
                                        // while media retains the original-source reference hashes.
                                        for url in try ASCMHL.artifacts(root:primary.url) {
                                            let (hash,size,_)=try ASCMHL.hashFile(url,checkpoint:{try self.pauseCheckpoint()})
                                            guard let value=self.fileMetadata(url) else {throw CopyError.verifyFailed("ASC artifact disappeared")}
                                            let path=url.pathComponents.dropFirst(root.count).joined(separator:"/")
                                            replicas.append(CopyEntry(source:url,relativePath:path,size:size));replicaMetadata[url.path]=value;hashes[url.path]=hash
                                        }
                                    }
                                    let planned=replicas,plannedMetadata=replicaMetadata,trustedHashes=hashes
                                    DispatchQueue.main.async {
                                        guard !self.cancelled else {preparingForward=false;return}
                                        do {
                                            guard let volume=VolumeIdentity(url:primary.url) else {throw CopyError.verifyFailed("Could not identify primary SSD for recovery.")}
                                            let files=planned.map{CascadeCheckpoint.File(relativePath:$0.relativePath,size:$0.size,checksum:trustedHashes[$0.source.path]!)}
                                            let checkpoint=CascadeCheckpoint(version:1,primary:primary.url,primaryVolume:volume,originalSources:sources,destinations:dests.map{$0.url},files:files,primaryReport:primaryWorker.lastReportURL)
                                            try checkpoint.validate(sources:sources,destinations:dests.map{$0.url},primary:primary.url)
                                            // Queue commits this snapshot atomically BEFORE handoff.
                                            try self.saveCascadeCheckpoint?(checkpoint)
                                            self.cascadeCheckpoint=checkpoint
                                        } catch {
                                            self.cascadeDependencyFailure=error.localizedDescription
                                            self.errorMessage=error.localizedDescription;preparingForward=false;self.cancel();return
                                        }
                                        if self.ascMHLEnabled {
                                            self.totalFiles=entries.count+planned.count*(dests.count-1)
                                            self.totalBytes=entries.reduce(Int64(0)){$0+$1.size}+planned.reduce(Int64(0)){$0+$1.size}*Int64(dests.count-1)
                                        }
                                        let cache=SharedSourceReadCache();self.sharedSourceReads=cache
                                        self.cascadeSourceReleased=true;self.cascadeSourceReleasedAt=Date()
                                        forwarded=true;preparingForward=false
                                        for d in dests where d.id != primary.id {
                                            let child=self.cascadeChild(sources:[primary.url],destination:d,entries:planned,metadata:plannedMetadata,hashes:trustedHashes,schedule:schedule,buffer:buffer,cache:cache)
                                            self.destinationWorkers.append((d,child));child.start()
                                            if self.disconnectedDestinationPaths.contains(d.url.standardizedFileURL.path) {self.disconnectDestination(d.url)}
                                            if self.isPaused {child.pauseTransfer()}
                                        }
                                    }
                                } catch {
                                    DispatchQueue.main.async {
                                        self.cascadeDependencyFailure=error.localizedDescription
                                        self.errorMessage=error.localizedDescription;preparingForward=false
                                        self.cancel()
                                    }
                                }
                            }
                            return
                        }
                        guard !preparingForward,!workers.contains(where:{$0.1.isRunning}) else{return}
                        // A verified primary is not success for the entire cascade.
                        let allVerified=forwarded && workers.count==dests.count && workers.allSatisfy{$0.1.lastRunWasVerified} && self.disconnectedDestinationPaths.isEmpty && self.cascadeDependencyFailure==nil && !self.cancelled
                        self.destinationTimer?.cancel();self.destinationTimer=nil
                        self.lastRunWasVerified=allVerified
                        self.state=allVerified ? .completed:(self.cascadeDependencyFailure != nil ? .failed:(self.cancelled ? .cancelled:.failed))
                        self.failCount=allVerified ? 0:max(1,self.failCount)
                        self.isolatedFailedDestinations=dests.filter { d in !workers.contains(where:{$0.0.id==d.id && $0.1.lastRunWasVerified}) }
                        self.lastReportURL=workers.compactMap{$0.1.lastReportURL}.first
                        self.statusText=allVerified ? "VERIFIED — SSD and all cascading destinations passed":(self.cascadeDependencyFailure ?? "Cascading incomplete — inspect destination results")
                        if !allVerified {self.errorMessage=self.cascadeDependencyFailure ?? workers.compactMap{$0.1.errorMessage}.first ?? self.statusText}
                        self.progress=1;self.phaseName="Finished";self.isPaused=false
                        self.speedBytesPerSecond=0;self.overallEtaSeconds=0;self.stopSleepPrevention()
                        self.completedSourceReadBytes=self.cascadeOriginalReadBytes+self.cascadeReplicaReadBytes
                        self.completedSharedReadStatistics=self.sharedSourceReads?.statistics;self.sharedSourceReads=nil
                        do {
                            let dir=self.historyDirectory();try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                            var history=self.readHistory()
                            history.insert(TransferHistoryRecord(id:UUID(),date:started,sources:sources.map{$0.path},destinations:dests.map{$0.url.path},bytes:self.totalBytes,files:self.totalFiles,verified:allVerified,status:self.statusText,reportPath:self.lastReportURL?.path),at:0)
                            try JSONEncoder().encode(Array(history.prefix(200))).write(to:dir.appendingPathComponent("history.json"),options:.atomic)
                            self.loadHistory()
                        } catch {self.errorMessage="Transfer reports exist, but local history could not be saved: "+error.localizedDescription}
                        self.destinationWorkers=[]
                    }
                    timer.resume()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isolationPreparing=false;self.state=self.cancelled ? .cancelled:.failed
                    self.errorMessage=error.localizedDescription;self.stopSleepPrevention()
                }
            }
        }
    }

    private func historyDirectory()->URL {
#if DEBUG
        if let path=ProcessInfo.processInfo.environment["NEFCOPY_TEST_HISTORY_DIRECTORY"] {
            return URL(fileURLWithPath:path,isDirectory:true)
        }
        if ProcessInfo.processInfo.processName.lowercased().contains("xctest") || NSClassFromString("XCTestCase") != nil {
            return Self.isolatedXCTestHistory
        }
#endif
        let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("NefCopy",isDirectory:true)
    }
    private var plannedBytesByDestination:[String:Int64]=[:]
    private var plannedFilesByDestination:[String:Int]=[:]
    private var plannedReportEntries:[String:[CopyEntry]]=[:]
    private var attemptedReportTargets=Set<String>()
    private var pendingReportHashes:[String:String]=[:]
    private var reportSourceNames:[String]=[]
    private var reportSourceURLs:[URL]=[]
    private func folderNames(_ sources:[URL])->[String] {
        if sources == reportSourceURLs && !reportSourceNames.isEmpty { return reportSourceNames }
        return sources.map { source in
            let isDirectory=(try? source.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true
            return (isDirectory ? source : source.deletingLastPathComponent()).lastPathComponent
        }
    }
    func writeTextReport(records:[ChecksumRecord],started:Date,status:String,bytes:Int64,files:Int,verified:Bool,sources:[URL],destinations:[URL],to txtURL:URL) throws {
        let enriched=records.map { record -> ChecksumRecord in
            var copy=record
            if copy.size == nil { copy.size=fileMetadata(URL(fileURLWithPath:record.source))?.0 }
            return copy
        }
        let diagnostics="I/O buffer policy: \(activeBufferSize.label)\nMeasured copy seconds: \(measuredCopySeconds)\nMeasured destination verify seconds: \(measuredVerifySeconds)\nFileHandle read seconds: \(ioReadSeconds)\nFileHandle write seconds: \(ioWriteSeconds)\nChecksum update seconds: \(ioHashSeconds)\nFile synchronization seconds: \(ioSyncSeconds)\nSource copy-read API bytes: \(sourceReadMetrics.readBytes)\nTiming note: API durations include cache effects, not physical-disk timings."
        let sourceDiagnostics="Independent source mode requested: \(independentSourceVerification)\nSource reference origin: \(sourceReferenceOrigin)\nIndependently pre-read files: \(sourceReferenceFileCount)\nSource reference bytes: \(sourceReferenceBytes)\nIndependent source read API bytes (this worker): \(independentSourceReadBytes)"
        let mhlDiagnostics="ASC MHL requested: \(ascMHLEnabled)\nASC MHL manifests: \(ascMHLManifestPaths.joined(separator:", "))"
        var text=TextLogRenderer.render(records:enriched,started:started,finished:Date(),status:status,bytes:bytes,files:files,verificationEnabled:verified,sourceNames:folderNames(sources),sources:sources,destinations:destinations,diagnostics:diagnostics+"\n"+sourceDiagnostics+"\n"+mhlDiagnostics)
        if independentSourceVerification {
            text=text.replacingOccurrences(of:"Verification mode: Full destination readback",with:"Verification mode: Independent source reference + full destination readback")
        }
        try text.write(to:txtURL,atomically:true,encoding:.utf8)
    }
    private func writeReports(records:[ChecksumRecord],started:Date,status:String,bytes:Int64,files:Int,verified:Bool,sources:[URL],destinations:[URL]) throws->URL {
        verifiedContentHashes=Dictionary(records.filter{$0.status == "PASS" && $0.sourceChecksum != "Not verified"}.map{($0.destination,$0.sourceChecksum)},uniquingKeysWith:{a,_ in a})
        let f=DateFormatter(); f.dateFormat="yyyy-MM-dd_HH-mm-ss"
        let stamp=f.string(from:started)
        let raw=folderNames(sources).joined(separator:"_")
        let normalized=String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn:" _-.")).contains(scalar) ? scalar : UnicodeScalar(95)!
        }))
        let safe=String(normalized.prefix(100))
        var firstTXT:URL?
        for destination in destinations {
            // Never recreate an unplugged /Volumes destination just to write a log.
            var isDirectory:ObjCBool=false
            let destinationExists=FileManager.default.fileExists(atPath:destination.path,isDirectory:&isDirectory) && isDirectory.boolValue
            let fallback=historyDirectory().appendingPathComponent("Recovered Logs",isDirectory:true)
            let dir=destinationExists ? destination.appendingPathComponent("NefCopy Reports",isDirectory:true) : fallback
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let prefix=destination.standardizedFileURL.pathComponents
            var subset=records.filter {
                let path=URL(fileURLWithPath:$0.destination).standardizedFileURL.pathComponents
                return path.count>prefix.count && Array(path.prefix(prefix.count)) == prefix
            }
            let entries=plannedReportEntries[destination.standardizedFileURL.path] ?? []
            let sizes=Dictionary(entries.map { (destination.appendingPathComponent($0.relativePath).path,$0.size) }, uniquingKeysWith: { first,_ in first })
            subset=subset.map { record in var copy=record; copy.size=sizes[record.destination]; return copy }
            let recorded=Set(subset.map{$0.destination})
            for entry in entries {
                let target=destination.appendingPathComponent(entry.relativePath).path
                guard !recorded.contains(target) else { continue }
                let pendingHash=pendingReportHashes[target]
                let outcome=pendingHash != nil ? "PENDING" : (attemptedReportTargets.contains(target) ? "INTERRUPTED" : "NOT TRANSFERRED")
                subset.append(ChecksumRecord(file:entry.relativePath,source:entry.source.path,destination:target,sourceChecksum:pendingHash ?? "Unavailable",destinationChecksum:"Not verified",status:outcome,size:entry.size))
            }
            let planned=plannedFilesByDestination[destination.standardizedFileURL.path] ?? files
            if ascMHLEnabled && verified && status == "COMPLETED / VERIFIED" {
                guard destinationExists,planned>0,subset.count==planned,subset.allSatisfy({$0.status=="PASS"}) else {
                    throw ASCMHL.Failure(message:"Incomplete or unavailable destination cannot receive verified history")
                }
                let manifest=try ASCMHL.appendVerified(root:destination,records:subset.filter { !$0.file.components(separatedBy:"/").contains("ascmhl") },started:ascMHLOperationStart,restoreRecordedEmptyDirectories:true,checkpoint:{try self.pauseCheckpoint()})
                if !(try ASCMHL.load(root:destination)).transfers.isEmpty {
                    let audit=try ASCMHL.verify(root:destination,checkpoint:{try self.pauseCheckpoint()})
                    guard audit.pendingTransfers==0 else {throw CopyError.verifyFailed("ASC transfer links need their common parent and both histories; only local copied files were checked")}
                }
                ascMHLManifestPaths.append(manifest.path)
            }
            var txt=dir.appendingPathComponent("NefCopy_\(safe.isEmpty ? "Source" : safe)_\(stamp)_\(UUID().uuidString.prefix(8))_report.txt")
            do {
            try writeTextReport(records:subset,started:started,status:status,bytes:plannedBytesByDestination[destination.standardizedFileURL.path] ?? bytes,files:planned,verified:verified,sources:sources,destinations:[destination],to:txt)
            } catch {
                try FileManager.default.createDirectory(at:fallback,withIntermediateDirectories:true)
                txt=fallback.appendingPathComponent(txt.lastPathComponent)
            try writeTextReport(records:subset,started:started,status:status,bytes:plannedBytesByDestination[destination.standardizedFileURL.path] ?? bytes,files:planned,verified:verified,sources:sources,destinations:[destination],to:txt)
            }
            if verified && destinationExists { updateVerifiedManifest(records:subset,destination:destination) }
            if firstTXT == nil { firstTXT=txt }
        }
        if !writesHistory { return firstTXT ?? historyDirectory() }
        let hdir=historyDirectory(); try FileManager.default.createDirectory(at:hdir,withIntermediateDirectories:true)
        var h=readHistory(); h.insert(TransferHistoryRecord(id:UUID(),date:started,sources:sources.map{$0.path},destinations:destinations.map{$0.path},bytes:bytes,files:files,verified:verified && status == "COMPLETED / VERIFIED",status:status,reportPath:firstTXT?.path),at:0)
        if h.count>200 { h=Array(h.prefix(200)) }
        try JSONEncoder().encode(h).write(to:hdir.appendingPathComponent("history.json"),options:.atomic)
        return firstTXT ?? hdir
    }
    private func readHistory()->[TransferHistoryRecord]{let u=historyDirectory().appendingPathComponent("history.json");guard let d=try? Data(contentsOf:u),let h=try? JSONDecoder().decode([TransferHistoryRecord].self,from:d) else{return []};return h}
    func reloadTransferHistory(){loadHistory()}
    func clearTransferHistory()throws {
        guard !isRunning else {throw CopyError.verifyFailed("Wait for the transfer to finish before clearing history.")}
        let dir=historyDirectory()
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try JSONEncoder().encode([TransferHistoryRecord]()).write(to:dir.appendingPathComponent("history.json"),options:.atomic)
        history=[]
    }
    private func loadHistory(){ history=readHistory() }
}
enum CopyError:LocalizedError{
    case cancelled,verifyFailed(String),duplicateConflict(String),freeSpaceUnavailable(String),insufficientSpace(String,Int64,Int64,String,String)
    var errorDescription:String?{
        switch self{
        case .cancelled:return "Transfer cancelled"
        case .verifyFailed(let f):return "Verification failed: \(f)"
        case .duplicateConflict(let f):return "Destination already contains a different file: \(f). Nothing was overwritten. Resolve the conflict in the destination before starting again."
        case .freeSpaceUnavailable(let d):return "Could not read available space for \(d). Transfer was not started."
        case .insufficientSpace(let d,_,_,let required,let available):return "\(d) does not have enough free space. Required: \(required); available: \(available). Transfer was not started."
        }
    }
}
