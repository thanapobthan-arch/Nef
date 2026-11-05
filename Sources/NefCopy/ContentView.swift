import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var queue:TransferQueue
    private var engine:CopyEngine {queue.draft}
    private var transferEngine:CopyEngine {selectedDetailsEngine ?? queue.displayedEngine ?? queue.draft}
    @StateObject private var mhlVerifier=ASCMHLVerifier()
    @StateObject private var diskActions=DiskActions()
    @State private var selectedDetailsEngine:CopyEngine?
    @State private var lastQueuedSignature:String?
    @State private var dropTarget = false
    @State private var destinationDropTarget = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showMHLTools = false
    @State private var showDetails = false
    @State private var showPreflight = false
    @State private var preflightResult = PreflightResult(ok: false, messages: [])
    @State private var preflightScanning = false
    @State private var preflightRequestID:UUID?
    @State private var labelURL: URL?
    @State private var labelDraft = ""
    @State private var showLabel = false
    @State private var labels: [String: String] = [:]
    private let driveTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let background = Color(red: 0.12, green: 0.12, blue: 0.14)

    var body: some View {
        VStack(spacing:16) {
            HStack(spacing:12) {
                Image(systemName:"chevron.forward.2").font(.system(size:25,weight:.bold)).foregroundStyle(.blue)
                Text("NefCopy").font(.system(size:25,weight:.bold))
                Spacer()
                Label("Queue",systemImage:"list.bullet").foregroundStyle(.blue).padding(9).background(Color.blue.opacity(0.12),in:RoundedRectangle(cornerRadius:8))
                QuietActionButton("History",systemImage:"clock",bordered:false){queue.reloadTransferHistory();showHistory=true}.fixedSize()
                QuietActionButton("",systemImage:"gearshape",bordered:false){showSettings=true}.fixedSize().help("Settings")
                    .disabled(selectionLocked)
            }.padding(.leading,58).padding(.top,10)
            HStack(alignment:.top,spacing:14) {
                sourcePanel.frame(maxWidth:.infinity)
                destinationPanel.frame(maxWidth:.infinity)
            }.frame(height:locationsHeight)
            HStack(spacing:10) {
            Button(action:primaryAction) {
                Label(primaryTitle,systemImage:queue.isBusy ? "plus":"play.fill")
                    .font(.system(size:18,weight:.semibold)).frame(maxWidth:.infinity).padding(.vertical,13)
                    .background(Color.blue,in:RoundedRectangle(cornerRadius:10)).foregroundStyle(.white)
            }.buttonStyle(.plain).disabled(selectionLocked || (queue.isBusy && draftSignature == lastQueuedSignature && !queue.isQueuePaused) || (engine.sourceURLs.isEmpty && !queue.hasPending) || (!engine.sourceURLs.isEmpty && engine.destinations.isEmpty))
            if preflightScanning {QuietActionButton("Cancel"){cancelPreflight()}.fixedSize()}
            }
            transferPanel
            overallFooter
        }.padding(18)
        .background(Color(red:0.035,green:0.06,blue:0.09))
        .frame(minWidth:700,idealWidth:820,minHeight:max(560,locationsHeight+330))
        .background(AdaptiveQueueWindow(idealHeight:idealWindowHeight))
        .focusedSceneValue(\.nefCopyActions, menuActions)
        .sheet(isPresented: $showSettings) { settingsView }
        .sheet(isPresented: $showMHLTools) { mhlToolsView }
        .sheet(isPresented: $showHistory) { historyView }
        .sheet(isPresented: $showDetails,onDismiss:{selectedDetailsEngine=nil}) { detailsView }
        .sheet(isPresented: $showPreflight, onDismiss: { cancelPreflight() }) { preflightView }
        .alert("Display label", isPresented: $showLabel) {
            TextField("Label", text: $labelDraft)
            Button("Save") {
                if let url = labelURL { labels[url.path] = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Changes the name shown in this window only. Files and folders are not renamed.") }
        .modifier(NoBlueFocus())
        .onReceive(driveTimer) { _ in if !engine.isRunning { engine.refreshMountedDrives() } }
    }

    private var selectionLocked: Bool {engine.isPreflighting || showPreflight || mhlVerifier.isRunning || diskActions.isEjecting}


    private var settingsSummary:String {
        engine.transferStrategy.rawValue+" · "+(engine.independentSourceVerification ? "Independent source + destination":"Destination readback")+(engine.ascMHLEnabled ? " · ASC MHL":"")
    }

    private var menuActions:NefCopyMenuActions {
        let modal=diskModalOpen
        return NefCopyMenuActions(
            canConfigure:!selectionLocked && !modal,
            canUseTools:!queue.isBusy && !selectionLocked && !modal,
            canShowResults:!modal,
            canCancel:mhlVerifier.isRunning,
            canClearSources:!selectionLocked && !modal && !engine.sourceURLs.isEmpty,
            canClearDestinations:!selectionLocked && !modal && !engine.destinations.isEmpty,
            canEjectSources:canEjectDisks && !DiskActions.targets(engine.sourceURLs).isEmpty,
            canEjectDestinations:canEjectDisks && !DiskActions.targets(engine.destinations.map{$0.url}).isEmpty,
            canEjectAll:canEjectDisks && !DiskActions.targets(engine.mountedDrives.map{$0.url}).isEmpty,
            clearSources:{clearDiskSelection(.sources)},
            clearDestinations:{clearDiskSelection(.destinations)},
            clearAll:{clearDiskSelection(.all)},
            ejectSources:{ejectDisks(engine.sourceURLs)},
            ejectDestinations:{ejectDisks(engine.destinations.map{$0.url})},
            ejectAll:{ejectDisks(engine.mountedDrives.map{$0.url})},
            settings:{showSettings=true},
            verify:{mhlVerifier.choose();if !mhlVerifier.status.isEmpty {showMHLTools=true}},
            rename:{mhlVerifier.chooseRename();if !mhlVerifier.status.isEmpty {showMHLTools=true}},
            transfer:{mhlVerifier.chooseTransfer();if !mhlVerifier.status.isEmpty {showMHLTools=true}},
            retry:{mhlVerifier.choosePendingTransfer();if !mhlVerifier.status.isEmpty {showMHLTools=true}},
            results:{showMHLTools=true},cancel:{mhlVerifier.cancel()})
    }

    private var diskModalOpen:Bool {showHistory || showDetails || showPreflight || showSettings || showMHLTools || showLabel}
    private var canEjectDisks:Bool {!selectionLocked && !diskModalOpen && !queue.isBusy && !queue.hasPending}
    private enum ClearDiskSelection {case sources,destinations,all}
    private func clearDiskSelection(_ scope:ClearDiskSelection) {
        guard !selectionLocked && !diskModalOpen else{return}
        if scope != .destinations {engine.clearSources()}
        if scope != .sources {engine.clearDestinations()}
    }
    private func ejectDisks(_ urls:[URL]) {
        diskActions.start(urls:urls,blocked:!canEjectDisks,confirm:{volumes in
            let alert=NSAlert();alert.messageText="Eject disks?"
            alert.informativeText="The following volumes will be safely unmounted and ejected:\n\n"+volumes.map{$0.lastPathComponent}.joined(separator:"\n")+"\n\nThis does not delete files or certify their checksums."
            alert.addButton(withTitle:"Eject");alert.addButton(withTitle:"Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        },completion:{message,hasErrors in
            engine.refreshMountedDrives()
            if hasErrors {
                let alert=NSAlert();alert.messageText="Some disks could not be ejected";alert.informativeText=message;alert.addButton(withTitle:"OK");alert.runModal()
            }
        })
    }

    private var settingsView:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {Text("Transfer Settings").font(.title2.bold());Spacer();Button("Done"){showSettings=false}.keyboardShortcut(.cancelAction)}
            Text("Applies to new jobs. Jobs already in the queue keep their saved settings.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Transfer mode",selection:Binding(get:{engine.transferStrategy},set:{ value in
                engine.transferStrategy=value
                if value == .cascading {engine.verifyEnabled=true}
            })) {ForEach(TransferStrategy.allCases) {Text($0.rawValue).tag($0)}}
                .disabled(selectionLocked)
            Picker("Verification",selection:Binding(get:{engine.independentSourceVerification},set:{ value in
                engine.independentSourceVerification=value;engine.verifyEnabled=true
            })) {
                Text("Destination readback").tag(false)
                Text("Independent source + destination").tag(true)
            }.disabled(selectionLocked)
            Text("Buffer: \(engine.ioBufferSize.label). Applies to new jobs.").font(.caption).foregroundStyle(.secondary)
            if engine.independentSourceVerification {
                Text("Read and hash each source before copying, then compare the copy and destination checksums. Adds a full source read.").font(.caption).foregroundStyle(.secondary)
            }
            if engine.transferStrategy == .cascading {
                Picker("Primary SSD",selection:Binding(get:{engine.cascadePrimaryDestination},set:{engine.cascadePrimaryDestination=$0})) {
                    Text("Choose primary SSD").tag(Optional<URL>.none)
                    ForEach(engine.destinations) {Text($0.url.path).tag(Optional($0.url))}
                }.disabled(selectionLocked)
                Text("Copy and verify the primary SSD first, then distribute from it. Choose a fast SSD; checksum verification is required.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Create ASC MHL",isOn:Binding(get:{engine.ascMHLEnabled},set:{value in
                engine.ascMHLEnabled=value;if value {engine.verifyEnabled=true}
            })).disabled(selectionLocked)

            Spacer(minLength:0)
        }.padding(24).frame(width:600,height:480)
    }

    private var mhlToolsView:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("ASC MHL").font(.title2.bold());Spacer();Button("Close"){showMHLTools=false}.keyboardShortcut(.cancelAction)}
            if mhlVerifier.isRunning {ProgressView();Button("Cancel verification"){mhlVerifier.cancel()}}
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text(mhlVerifier.status.isEmpty ? "Choose an operation from Tools → ASC MHL.":mhlVerifier.status).textSelection(.enabled)
                    if !mhlVerifier.movedOutFiles.isEmpty {
                        Text("Moved-out files").font(.headline)
                        ForEach(mhlVerifier.movedOutFiles,id:\.self) {path in Text("Moved out: "+path).font(.caption).textSelection(.enabled)}
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(24).frame(width:650,height:390)
    }

    private var locationsHeight:CGFloat {
        64+CGFloat(min(3,max(1,max(engine.sourceURLs.count,engine.destinations.count))))*64
    }
    private var idealWindowHeight:CGFloat {locationsHeight+270+CGFloat(min(4,max(1,queue.jobs.count)))*110}
    private var draftSignature:String {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(TransferJobSettings(engine:engine)).base64EncodedString()) ?? ""
    }
    private var primaryTitle:String {
        if preflightScanning {return "Checking…"}
        if draftSignature == lastQueuedSignature && (queue.isBusy || queue.hasPending) {
            return queue.isQueuePaused ? "Resume Queue":queue.isBusy ? "Queue Running":"Start Queue"
        }
        return queue.isBusy ? "Add to Queue":"Start Queue"
    }
    private func primaryAction() {
        guard !selectionLocked else{return}
        if draftSignature == lastQueuedSignature && (queue.isBusy || queue.hasPending) {queue.resumeQueue();return}
        if !engine.sourceURLs.isEmpty {beginPreflight()}
        else if queue.hasPending {queue.resumeQueue()}
    }
    private func panelHeader(_ title:String,count:Int,icon:String,add:@escaping()->Void)->some View {
        HStack {
            Label("\(title) (\(count))",systemImage:icon).font(.headline)
            Spacer(minLength:4)
            Button(action:add) {Label("Add",systemImage:"plus")}.disabled(selectionLocked)
        }
    }
    private var sourcePanel:some View {
        VStack(alignment:.leading,spacing:10) {
            panelHeader("Sources",count:engine.sourceURLs.count,icon:"folder.fill",add:{engine.chooseSource()})
            Divider()
            ScrollView {
                VStack(spacing:8) {
                    ForEach(engine.sourceURLs,id:\.self) {url in
                        HStack(spacing:10) {
                            fileIcon(url,size:40)
                            VStack(alignment:.leading,spacing:4) {
                                Text(displayName(url)).font(.callout.bold()).lineLimit(1).help(url.path)
                                Text(engine.sourceURLs.count==1 ? "\(sizeText(engine.totalBytes)) · \(engine.totalFiles) files":url.path)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength:0)
                            Menu {sourceActions(url)} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:18)
                        }.padding(.vertical,5).contextMenu{sourceActions(url)}
                         .onDrag{NSItemProvider(object:url as NSURL)}
                    }
                    if engine.sourceURLs.isEmpty {Text("Drop files or folders here").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:45)}
                }
            }
        }.padding(14).background(panelBackground,in:RoundedRectangle(cornerRadius:12))
         .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.white.opacity(0.1)))
         .overlay{dropHighlight(dropTarget && !selectionLocked)}
         .onDrop(of:[UTType.fileURL.identifier],isTargeted:$dropTarget){handleDrop($0)}
    }
    private var destinationPanel:some View {
        VStack(alignment:.leading,spacing:10) {
            panelHeader("Destinations",count:engine.destinations.count,icon:"externaldrive.fill",add:{engine.addDestination()})
            Divider()
            ScrollView {
                VStack(spacing:8) {
                    ForEach(engine.destinations) {destination in
                        HStack(spacing:10) {
                            fileIcon(destination.url,size:40)
                            VStack(alignment:.leading,spacing:4) {
                                Text(displayName(destination.url)).font(.callout.bold()).lineLimit(1).help(destination.url.path)
                                Text(freeText(destination.url)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength:0)
                            Menu {destinationActions(destination)} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:18)
                        }.padding(.vertical,5).contextMenu{destinationActions(destination)}
                         .onDrag{NSItemProvider(object:destination.url as NSURL)}
                    }
                    if engine.destinations.isEmpty {Text("Drop destination folders here").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:45)}
                }
            }
        }.padding(14).background(panelBackground,in:RoundedRectangle(cornerRadius:12))
         .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.white.opacity(0.1)))
         .overlay{dropHighlight(destinationDropTarget && !selectionLocked)}
         .onDrop(of:[UTType.fileURL.identifier],isTargeted:$destinationDropTarget){handleDestinationDrop($0)}
    }
    private var panelBackground:Color {Color(red:0.055,green:0.085,blue:0.12)}

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)
    }

    private var itemTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity)
    }

    private func dropHighlight(_ active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(active ? 0.08 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(active ? 0.85 : 0), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
            .padding(8)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: active)
    }

    private func emptyDrop(_ title: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "plus").font(.title)
            Text(title).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).frame(height: 250)
         .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [8, 8])))
    }

    private func fileIcon(_ url: URL, size: CGFloat) -> some View {
        Image(nsImage: OffloadIconCache.icon(for: url))
            .resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func displayName(_ url: URL) -> String {
        if let label = labels[url.path], !label.isEmpty { return label }
        return FileManager.default.displayName(atPath: url.path)
    }

    @ViewBuilder private func sourceActions(_ url: URL) -> some View {
        Button("Source Folder…") { chooseFolder(replacing: url, source: true) }.disabled(selectionLocked)
        Button("Add Label…") { editLabel(url) }
        Divider()
        Button("Remove from Sources") { engine.removeSource(url) }.disabled(selectionLocked)
        Button("Set as Destination") {
            guard !selectionLocked else { return }
            engine.removeSource(url); engine.addDestinationURL(url)
        }.disabled(selectionLocked || !isDirectory(url))
        Divider()
        if engine.canSafeEject { Button("Safe Eject Sources") { engine.ejectSources() } }
        Button("Show in Finder") { engine.reveal(url) }
    }

    @ViewBuilder private func destinationActions(_ destination: Destination) -> some View {
        Button("Destination Folder…") { chooseFolder(replacing: destination.url, source: false) }.disabled(selectionLocked)
        Button("Add Label…") { editLabel(destination.url) }
        Divider()
        Button("Remove from Destinations") { engine.removeDestination(destination) }.disabled(selectionLocked)
        Button("Set as Source") {
            guard !selectionLocked else { return }
            engine.removeDestination(destination); engine.addSourceURL(destination.url)
        }.disabled(selectionLocked)
        Divider()
        Button("Show in Finder") { engine.reveal(destination.url) }
    }

    private func editLabel(_ url: URL) { labelURL = url; labelDraft = labels[url.path] ?? ""; showLabel = true }
    private func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    private func chooseFolder(replacing url: URL, source: Bool) {
        guard !selectionLocked else { return }
        let panel = NSOpenPanel()
        panel.title = source ? "Choose Source Folder" : "Choose Destination Folder"
        panel.directoryURL = isDirectory(url) ? url : url.deletingLastPathComponent()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url, !selectionLocked else { return }
        if source { engine.removeSource(url); engine.addSourceURL(selected) }
        else if let destination = engine.destinations.first(where: { $0.url == url }) {
            engine.removeDestination(destination); engine.addDestinationURL(selected)
        }
    }

    private var availableDrives: [MountedDrive] {
        let selected = Set((engine.sourceURLs + engine.destinations.map { $0.url }).map { $0.standardizedFileURL.path })
        return engine.mountedDrives.filter { !selected.contains($0.url.standardizedFileURL.path) }
    }

    private static let queueDragType="local.nefcopy.waiting-job"
    private var transferPanel:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label("Transfer Queue (\(queue.jobs.count))",systemImage:"list.bullet").font(.headline)
                Spacer()
                Menu {
                    Button(queue.isQueuePaused ? "Resume Queue":"Pause after current job") {
                        if queue.isQueuePaused {queue.resumeQueue()} else {queue.pauseQueue()}
                    }
                    Button("Stop All"){queue.cancelAll()}.disabled(!queue.isBusy && !queue.hasPending)
                } label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:24)
            }
            if let error=queue.errorMessage {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
            ScrollView {
                LazyVStack(spacing:8) {
                    ForEach(Array(queue.jobs.enumerated()),id:\.element.id) {index,job in
                        VerticalQueueRow(job:job,index:index+1,queue:queue,onDetails:{worker in selectedDetailsEngine=worker;showDetails=true})
                            .onDrop(of:[Self.queueDragType],isTargeted:nil){providers in receiveQueueDrop(providers,before:job.id)}
                    }
                    if queue.jobs.isEmpty {Text("No transfers yet. Add sources and destinations, then Start Queue.").foregroundStyle(.secondary).font(.callout).frame(maxWidth:.infinity,minHeight:90)}
                    else if queue.hasPending {
                        Text("Drag waiting jobs to reorder").font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:24)
                            .onDrop(of:[Self.queueDragType],isTargeted:nil){providers in receiveQueueDrop(providers,before:nil)}
                    }
                }
            }
            HStack {
                Spacer()
                QuietActionButton("Clear Queue") {queue.clearInactiveJobs()}.fixedSize()
                    .disabled(!queue.jobs.contains{$0.id != queue.activeJobID})
                    .help("Remove waiting and finished jobs. The active transfer, files and reports are kept.")
            }
        }.padding(14).background(panelBackground,in:RoundedRectangle(cornerRadius:12))
         .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.white.opacity(0.1)))
    }
    private func receiveQueueDrop(_ providers:[NSItemProvider],before target:UUID?)->Bool {
        guard let provider=providers.first(where:{$0.hasItemConformingToTypeIdentifier(Self.queueDragType)}),
              target == nil || queue.jobs.contains(where:{$0.id==target && $0.state == .queued}) else{return false}
        provider.loadDataRepresentation(forTypeIdentifier:Self.queueDragType) {data,_ in
            guard let data,data.count<=64,let text=String(data:data,encoding:.utf8),let id=UUID(uuidString:text) else{return}
            DispatchQueue.main.async {queue.moveWaitingJob(id,before:target)}
        }
        return true
    }
    private var overallFooter:some View {
        let rows=queue.jobs.map{QueueRowPresentation(job:$0)},fraction=QueueRowPresentation.overall(rows)
        let verified=rows.filter{$0.fraction==1}.count
        return VStack(spacing:7) {
            HStack {
                Text("Overall Progress").font(.caption.bold())
                Text("\(verified) of \(queue.jobs.count) verified · by job").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if queue.canEjectDisplayedSources {
                    Button("Eject verified sources"){ejectDisks(queue.jobs.filter{$0.state == .verified}.flatMap{$0.settings.sources})}
                        .font(.caption).disabled(!canEjectDisks || DiskActions.targets(queue.jobs.filter{$0.state == .verified}.flatMap{$0.settings.sources}).isEmpty)
                }
                Text("\(Int((fraction*100).rounded(.down)))%").font(.caption).monospacedDigit()
            }
            QueueProgressBar(value:fraction)
        }
    }

    private var presentation: TransferPresentation {
        TransferPresentation(state: transferEngine.state, progress: transferEngine.progress, verified: transferEngine.lastRunWasVerified, hasError: transferEngine.errorMessage != nil)
    }

    private var progressColor: Color {
        if transferEngine.isPaused || transferEngine.errorMessage != nil || transferEngine.state == .failed || transferEngine.state == .cancelled { return .orange }
        if transferEngine.state == .completed { return transferEngine.lastRunWasVerified ? .green : .orange }
        return .accentColor
    }

    private var detailsView: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Transfer details").font(.title2.bold()); Spacer()
                Button("Close") { showDetails = false }.keyboardShortcut(.cancelAction)
            }
            ScrollView { transferCard }
            HStack { Text(transferEngine.statusText).font(.caption); Spacer() }
        }.padding(24).frame(width: 760, height: 520)
    }

    private var transferCard: some View {
        VStack(alignment:.leading, spacing: 14) {
            HStack {
                Image(systemName: stateIcon).font(.system(size: 30))
                VStack(alignment:.leading) {
                    Text("\(transferEngine.sourceName)  →  \(destinationSummary)").font(.headline)
                    Text(transferEngine.currentFile.isEmpty ? transferEngine.statusText : transferEngine.currentFile).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Text(transferEngine.isPaused ? "Stopped — ready to resume" : (transferEngine.destinationProgress.isEmpty ? presentation.title:transferEngine.statusText)).font(.caption.bold())
            }
            if presentation.showsLiveMetrics && !transferEngine.isPaused {
                Text("Now: \(transferEngine.phaseName)").font(.caption.bold())
                TimelineView(.periodic(from:.now,by:1)) { context in
                    if context.date.timeIntervalSince(transferEngine.lastActivityAt)>10 {
                        Text("Waiting for I/O — no byte progress for \(Int(context.date.timeIntervalSince(transferEngine.lastActivityAt)))s")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Text(transferEngine.verifyEnabled ? "Overall — Copy + Verify" : "Overall — Copy only / NOT VERIFIED").font(.caption)
            ProgressView(value: presentation.fraction)
            HStack {
                Text("\(presentation.percent)% • \(transferEngine.completedFiles)/\(transferEngine.totalFiles) files")
                Spacer()
                if presentation.showsLiveMetrics && !transferEngine.isPaused { Text(speedText) }
                else if transferEngine.state == .completed { Text("\(transferEngine.passCount) PASS • \(transferEngine.failCount) FAIL").foregroundStyle(transferEngine.failCount == 0 ? .green : .red) }
            }.font(.caption).foregroundStyle(.secondary)
            Text("Copied: \(transferEngine.copiedFileCount) • Pending verification: \(transferEngine.pendingVerifyFileCount) • Verified: \(transferEngine.verifyEnabled ? transferEngine.passCount : 0) • Failed: \(transferEngine.failCount)")
                .font(.caption).foregroundStyle(.secondary)
            Text(String(format:"Elapsed: %.0fs • Copy processing: %.0fs • Verify processing: %.0fs",transferEngine.elapsedSeconds,transferEngine.copyProcessingSeconds,transferEngine.verifyProcessingSeconds))
                .font(.caption).foregroundStyle(.secondary)
            if transferEngine.isRunning && transferEngine.verifyEnabled && transferEngine.state == .copying {
                Text("Overall ETA uses an estimated Verify rate until destination verification starts.").font(.caption).foregroundStyle(.secondary)
            }
            if transferEngine.state == .completed {
                Text(transferEngine.lastRunWasVerified ? "Verified — all files passed. Open Reports for the TXT summary." : "Copy finished without full verification. Keep source files.")
                    .font(.caption.bold()).foregroundStyle(transferEngine.lastRunWasVerified ? .green : .orange)
            } else if transferEngine.state == .failed || transferEngine.state == .cancelled {
                Text("Not fully verified — keep source files and check the TXT report.").font(.caption.bold()).foregroundStyle(.orange)
            }
            if presentation.showsLiveMetrics && !transferEngine.isPaused {
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Text(transferEngine.verifyEnabled ? "All files — Copy + Verify" : "All files — Copy only / NOT VERIFIED")
                        Spacer()
                        Text(transferEngine.phaseTotalBytes < 0 ? "Calculating…" : formattedETA(transferEngine.overallEtaSeconds))
                    }
                }.font(.caption).monospacedDigit()
            }
        }.padding(22).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var preflightView: some View {
        VStack(alignment:.leading, spacing: 16) {
            HStack { Text("Pre-flight Check").font(.title2.bold()); Spacer(); QuietActionButton("Close",escapeKey:true){cancelPreflight()}.fixedSize() }
            Text("Checks space and duplicate files before starting. Existing files without a valid verification cache require full checksum reads; this can take time on large files.").foregroundStyle(.secondary)
            if preflightScanning {
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text(engine.preflightStatus).font(.callout.weight(.medium)); Spacer(); Text(String(format:"%.1f%%",engine.preflightProgress*100)).font(.system(.callout,design:.monospaced).bold()) }
                    ProgressView(value:engine.preflightProgress).progressViewStyle(.linear)
                    if engine.phaseName == "Checking existing file" {
                        Text("Checking existing file").font(.caption)
                    }
                    Text("Fast scan uses the previous verified NefCopy manifest when file metadata is unchanged; otherwise it falls back to full XXH64BE.").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical,8)
            }
            ScrollView {
                VStack(alignment:.leading, spacing:10) {
                    ForEach(Array(preflightResult.messages.enumerated()), id: \.offset) { _, m in
                        HStack(alignment:.top) {
                            Image(systemName: m.hasPrefix("FAIL") ? "xmark.circle.fill" : (m.hasPrefix("WARNING") ? "exclamationmark.triangle.fill" : (m.hasPrefix("SKIP") ? "forward.fill" : "checkmark.circle.fill")))
                            Text(m).textSelection(.enabled)
                        }.foregroundStyle(m.hasPrefix("FAIL") ? .red : (m.hasPrefix("WARNING") ? .orange : (m.hasPrefix("SKIP") ? .yellow : .green)))
                    }
                }.frame(maxWidth:.infinity, alignment:.leading)
            }
            HStack { Spacer(); QuietActionButton("Cancel"){cancelPreflight()}.fixedSize(); Button(queue.isBusy ? "Add to Queue":"Start Queue") {
                commitCheckedSources()
            }.buttonStyle(.borderedProminent).disabled(preflightScanning || !preflightResult.ok) }
        }.padding(24).frame(width: 760, height: 520)
    }

    private func cancelPreflight() {
        preflightRequestID=nil;preflightScanning=false
        engine.cancelPreflight();showPreflight=false
    }
    private func commitCheckedSources() {
        let wasBusy=queue.isBusy
        let ids=queue.enqueueSourceBatch(TransferJobSettings(engine:engine))
        if !ids.isEmpty {lastQueuedSignature=draftSignature;showPreflight=false;if !wasBusy {queue.resumeQueue()}}
    }
    private func beginPreflight() {
        guard !selectionLocked else{return}
        let requestID=UUID();preflightRequestID=requestID
        preflightScanning=true
        engine.runPreflight {result in
            guard preflightRequestID==requestID else{return}
            preflightRequestID=nil;preflightScanning=false;preflightResult=result
            if PreflightRouting.requiresAttention(result) {showPreflight=true}
            else {commitCheckedSources()}
        }
    }

    private var historyView:some View {TransferHistoryView(queue:queue,onClose:{showHistory=false})}

    private func handleDrop(_ ps:[NSItemProvider]) -> Bool {
        guard !selectionLocked else { return false }
        var urls:[URL]=[]; let g=DispatchGroup(), lock=NSLock()
        for p in ps where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            g.enter(); p.loadItem(forTypeIdentifier:UTType.fileURL.identifier, options:nil) { item,_ in
                defer { g.leave() }; var u:URL?
                if let data=item as? Data { u=URL(dataRepresentation:data,relativeTo:nil) } else if let x=item as? URL { u=x }
                if let u { lock.lock(); urls.append(u); lock.unlock() }
            }
        }
        g.notify(queue:.main) { engine.addDroppedSources(urls) }
        return ps.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }

    private func handleDestinationDrop(_ ps:[NSItemProvider]) -> Bool {
        guard !selectionLocked else { return false }
        var urls:[URL]=[]; let g=DispatchGroup(), lock=NSLock()
        for p in ps where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            g.enter(); p.loadItem(forTypeIdentifier:UTType.fileURL.identifier, options:nil) { item,_ in
                defer { g.leave() }; var u:URL?
                if let data=item as? Data { u=URL(dataRepresentation:data,relativeTo:nil) } else if let x=item as? URL { u=x }
                if let u {
                    var isDir:ObjCBool=false
                    if FileManager.default.fileExists(atPath:u.path,isDirectory:&isDir), isDir.boolValue { lock.lock(); urls.append(u); lock.unlock() }
                }
            }
        }
        g.notify(queue:.main) { for u in urls { engine.addDestinationURL(u) } }
        return ps.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }

    private var destinationSummary:String { transferEngine.destinations.count == 1 ? transferEngine.destinations[0].name : "\(transferEngine.destinations.count) destinations" }
    private var speedText:String { "\(ByteCountFormatter.string(fromByteCount:Int64(transferEngine.speedBytesPerSecond),countStyle:.file))/s" }
    private var etaText:String { formattedETA(transferEngine.etaSeconds) }
    private func formattedETA(_ seconds:Double)->String {
        guard seconds.isFinite,seconds>0 else { return "Calculating…" }
        if seconds<1 { return "Less than 1s" }
        let formatter=DateComponentsFormatter()
        formatter.allowedUnits=seconds>=3600 ? [.hour,.minute] : [.minute,.second]
        formatter.unitsStyle = .abbreviated
        return "About \(formatter.string(from:seconds) ?? "—") remaining"
    }
    private var stateIcon:String { switch transferEngine.state { case .completed:return "checkmark.circle.fill"; case .failed:return "exclamationmark.triangle.fill"; case .cancelled:return "stop.circle"; default:return "externaldrive.fill" } }
    private func sizeText(_ b:Int64)->String { ByteCountFormatter.string(fromByteCount:b,countStyle:.file) }
    private func freeText(_ url: URL) -> String {
        // Use the periodic drive snapshot rather than filesystem calls during animation.
        let components = url.standardizedFileURL.pathComponents
        let drive = engine.mountedDrives.sorted { $0.url.pathComponents.count > $1.url.pathComponents.count }.first {
            let root = $0.url.standardizedFileURL.pathComponents
            return components.starts(with: root)
        }
        return drive.map { "\(sizeText($0.available)) available" } ?? "Space checked before transfer"
    }

}

/// Subtle selection outline like the reference; does not intercept drag or menu clicks.
private struct OffloadHoverFrame: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hovering ? 0.025 : 0)))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.white.opacity(hovering ? 0.45 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }
}

private enum OffloadIconCache {
    static let images = NSCache<NSString, NSImage>()
    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let image = images.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        images.countLimit = 128
        images.setObject(image, forKey: key)
        return image
    }
}

/// Retains native button/keyboard semantics without the blue focus-ring decoration.
private struct PageSwitchButton: NSViewRepresentable {
    let title: String
    let pointsUp: Bool
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.activate))
        button.isBordered = false
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.imagePosition = .imageRight
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.image = NSImage(systemSymbolName: pointsUp ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        button.toolTip = "Switch between Disks and Transfers"
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}
