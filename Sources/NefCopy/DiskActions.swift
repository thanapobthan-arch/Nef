import Foundation
import AppKit
import Combine

final class DiskActions:ObservableObject {
    @Published private(set) var isEjecting=false
    @Published private(set) var status=""

    // Ask macOS for the containing volume; a selected folder is not itself a disk.
    // Fail closed for internal, network, unknown and system volumes.
    static func externalVolume(_ url:URL)->URL? {
        guard url.isFileURL,
              let values=try? url.standardizedFileURL.resolvingSymlinksInPath().resourceValues(forKeys:[.volumeURLKey,.volumeIsInternalKey,.volumeIsLocalKey]),
              values.volumeIsInternal == false,values.volumeIsLocal == true,
              let volume=values.volume else{return nil}
        return volume.standardizedFileURL.resolvingSymlinksInPath()
    }
    static func targets(_ urls:[URL],resolve:(URL)->URL? = DiskActions.externalVolume)->[URL] {
        var seen=Set<String>()
        return urls.compactMap {url in
            guard url.isFileURL,let volume=resolve(url),volume.isFileURL else{return nil}
            let canonical=volume.standardizedFileURL.resolvingSymlinksInPath(),parts=canonical.pathComponents
            guard parts.count==3,parts[1]=="Volumes",seen.insert(canonical.path).inserted else{return nil}
            return canonical
        }.sorted{$0.path.localizedStandardCompare($1.path) == .orderedAscending}
    }

    func start(urls:[URL],blocked:Bool,
               resolve:(URL)->URL? = DiskActions.externalVolume,
               confirm:([URL])->Bool,
               eject:@escaping (URL)throws->Void = {try NSWorkspace.shared.unmountAndEjectDevice(at:$0)},
               completion:@escaping (String,Bool)->Void = {_,_ in}) {
        precondition(Thread.isMainThread)
        guard !isEjecting,!blocked else{return}
        let volumes=Self.targets(urls,resolve:resolve)
        guard !volumes.isEmpty else{status="No eligible external disks selected.";return}
        isEjecting=true
        guard confirm(volumes) else{isEjecting=false;status="Eject cancelled.";return}
        status="Ejecting disks…"
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            var messages:[String]=[],failed=false
            for volume in volumes {
                do {try eject(volume);messages.append("Ejected: "+volume.lastPathComponent)}
                catch {failed=true;messages.append("Could not eject "+volume.lastPathComponent+": "+error.localizedDescription)}
            }
            let message=messages.joined(separator:"\n"),hasErrors=failed
            DispatchQueue.main.async { [self] in
                status=message;isEjecting=false;completion(message,hasErrors)
            }
        }
    }
}
