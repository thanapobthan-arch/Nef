import Foundation
import AppKit
import Combine

final class ASCMHLVerifier:ObservableObject {
    @Published private(set) var isRunning=false
    @Published private(set) var status=""
    @Published private(set) var movedOutFiles:[String]=[]
    private final class Token {
        private let lock=NSLock();private var cancelled=false
        func cancel(){lock.lock();cancelled=true;lock.unlock()}
        func checkpoint()throws {lock.lock();let value=cancelled;lock.unlock();if value {throw CopyError.cancelled}}
    }
    private var token:Token?
    func choose() {
        guard !isRunning else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.message="Choose the folder containing the ascmhl folder. Recorded files, directory hashes and nested histories will be checked."
        if panel.runModal() == .OK,let url=panel.url {start(root:url)}
    }
    func chooseRename() {
        guard !isRunning else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.message="Choose the folder containing the ASC MHL history. The file must already have been renamed or moved."
        guard panel.runModal() == .OK,let root=panel.url else{return}
        do {
            let history=try ASCMHL.load(root:root),missing=try history.files.keys.filter{!(try ASCMHL.hasExactPath(root:root,path:$0))}.sorted()
            guard !missing.isEmpty else {status="No recorded file is missing. Rename or move the file first.";return}
            let alert=NSAlert();alert.messageText="Select the previous file path";alert.informativeText="NefCopy will validate the new file against this original checksum."
            let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:500,height:30));picker.addItems(withTitles:missing);alert.accessoryView=picker
            alert.addButton(withTitle:"Choose renamed file…");alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn,let previous=picker.titleOfSelectedItem else{return}
            let file=NSOpenPanel();file.canChooseDirectories=false;file.canChooseFiles=true;file.allowsMultipleSelection=false;file.directoryURL=root
            guard file.runModal() == .OK,let target=file.url else{return}
            let rp=root.standardizedFileURL.resolvingSymlinksInPath().pathComponents,tp=target.standardizedFileURL.pathComponents
            guard tp.count>rp.count,tp.starts(with:rp) else {status="The renamed file must remain inside the selected history root.";return}
            startRename(root:root,previousPath:previous,newPath:tp.dropFirst(rp.count).joined(separator:"/"))
        } catch {status="ASC MHL rename did not pass: "+error.localizedDescription}
    }
    func startRename(root:URL,previousPath:String,newPath:String) {
        guard !isRunning else{return}
        let token=Token();self.token=token;isRunning=true;movedOutFiles=[];status="Checking and recording file rename…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result {try ASCMHL.recordRename(root:root,previousPath:previousPath,newPath:newPath,checkpoint:{try token.checkpoint()})}
            DispatchQueue.main.async {
                guard let self else{return};self.isRunning=false;self.token=nil
                switch result {
                case .success(let value):self.status="ASC MHL rename recorded and verified: \(value.files) files."
                case .failure(let error):self.status="ASC MHL rename did not pass: "+error.localizedDescription
                }
            }
        }
    }
    func chooseTransfer() {
        guard !isRunning else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.message="Choose the common parent containing both histories. Move the file in Finder first; NefCopy records the verified transfer."
        guard panel.runModal() == .OK,let root=panel.url else{return}
        do {
            let history=try ASCMHL.load(root:root),missing=try history.files.keys.filter{!(try ASCMHL.hasExactPath(root:root,path:$0))}.sorted()
            guard !missing.isEmpty else {status="No unrecorded moved-out file found. For interrupted operations, inspect the transfer journal before retry.";return}
            let alert=NSAlert();alert.messageText="Select the moved-out file";alert.informativeText="The old path will become an explicit ASC ignore. A NefCopy receipt will link it to the verified destination; use the common parent to audit the complete transfer."
            let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:500,height:30));picker.addItems(withTitles:missing);alert.accessoryView=picker
            alert.addButton(withTitle:"Choose destination file…");alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn,let previous=picker.titleOfSelectedItem else{return}
            let target=NSOpenPanel();target.canChooseFiles=true;target.canChooseDirectories=false;target.allowsMultipleSelection=false;target.directoryURL=root
            guard target.runModal() == .OK,let url=target.url else{return}
            let rp=root.standardizedFileURL.resolvingSymlinksInPath().pathComponents,tp=url.standardizedFileURL.pathComponents
            guard tp.count>rp.count,tp.starts(with:rp) else {status="Destination must remain inside the selected common parent.";return}
            startTransfer(root:root,previousPath:previous,newPath:tp.dropFirst(rp.count).joined(separator:"/"))
        } catch {status="Cross-history move was not recorded: "+error.localizedDescription}
    }
    func choosePendingTransfer() {
        guard !isRunning else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.message="Choose the common parent containing the pending NefCopy transfer journal."
        guard panel.runModal() == .OK,let root=panel.url else{return}
        do {
            let pending=try ASCMHL.pendingTransferPayloads(root:root)
            guard !pending.isEmpty else {status="No pending transfer receipts in this folder.";return}
            let alert=NSAlert();alert.messageText="Retry a pending transfer receipt";alert.informativeText="All media, ownership and the original history will be checked again before continuing. A stale writer lock must be inspected before retry."
            let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:500,height:30));picker.addItems(withTitles:pending.map{$0.source+" → "+$0.destination});alert.accessoryView=picker
            alert.addButton(withTitle:"Retry");alert.addButton(withTitle:"Cancel")
            if alert.runModal() == .alertFirstButtonReturn {let payload=pending[picker.indexOfSelectedItem];startTransfer(root:root,previousPath:payload.source,newPath:payload.destination)}
        } catch {status="Pending transfer cannot be retried: "+error.localizedDescription}
    }
    func startTransfer(root:URL,previousPath:String,newPath:String) {
        guard !isRunning else{return}
        let token=Token();self.token=token;isRunning=true;movedOutFiles=[];status="Verifying destination and recording the transfer receipt…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result {
                let value=try ASCMHL.recordCrossHistoryMove(root:root,previousPath:previousPath,newPath:newPath,checkpoint:{try token.checkpoint()})
                return (value,try ASCMHL.load(root:root).retired.keys.sorted())
            }
            DispatchQueue.main.async {
                guard let self else{return};self.isRunning=false;self.token=nil
                switch result {
                case .success(let (value,paths)):self.movedOutFiles=paths;self.status="Transfer recorded: \(value.transferredOut) moved out; \(value.transferLinks) links and \(value.files) current files verified."
                case .failure(let error):self.status="Transfer not fully verified; inspect the journal before retry: "+error.localizedDescription
                }
            }
        }
    }
    func cancel(){token?.cancel()}
    func start(root:URL) {
        guard !isRunning else{return}
        let token=Token();self.token=token;isRunning=true;movedOutFiles=[];status="Checking ASC MHL history and listed files…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result {
                let value=try ASCMHL.verifyAndRecord(root:root,checkpoint:{try token.checkpoint()})
                return (value,try ASCMHL.load(root:root).retired.keys.sorted())
            }
            DispatchQueue.main.async {
                guard let self else{return}
                self.isRunning=false;self.token=nil
                switch result {
                case .success(let (value,paths)):
                    self.movedOutFiles=paths
                    if value.pendingTransfers>0 {self.status="Local files checked: \(value.files); moved out: \(value.transferredOut). \(value.pendingTransfers) transfer link(s) require the common parent. This is not a full transfer verification."}
                    else {self.status="ASC MHL verified: \(value.files) files, \(value.generations) generation(s); moved out: \(value.transferredOut), verified transfer links: \(value.transferLinks)."}
                case .failure(let error):self.status="ASC MHL verification did not pass: "+error.localizedDescription
                }
            }
        }
    }
}
