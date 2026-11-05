import SwiftUI
import UniformTypeIdentifiers

extension QueueStatusTone {
    var color:Color {
        switch self {
        case .neutral:return .secondary
        case .copying,.success:return .green
        case .verifying:return .blue
        case .paused,.warning:return .orange
        case .failure:return .red
        }
    }
}
struct VerticalQueueRow:View {
    let job:QueuedTransferJob
    let index:Int
    @ObservedObject var queue:TransferQueue
    let onDetails:(CopyEngine)->Void
    private var presentation:QueueRowPresentation {QueueRowPresentation(job:job)}
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:10) {
                if job.state == .queued {
                    Image(systemName:"line.3.horizontal").foregroundStyle(.secondary)
                        .onDrag{NSItemProvider(item:Data(job.id.uuidString.utf8) as NSData,typeIdentifier:"local.nefcopy.waiting-job")}
                        .help("Drag to reorder waiting jobs")
                        .accessibilityLabel("Reorder "+job.name)
                } else {Image(systemName:"line.3.horizontal").foregroundStyle(.quaternary).accessibilityHidden(true)}
                Text("\(index)").font(.caption.bold()).monospacedDigit().frame(width:16)
                Image(systemName:"folder.fill").font(.system(size:32)).foregroundStyle(.blue)
                VStack(alignment:.leading,spacing:5) {
                    Text(job.name).font(.callout.bold()).lineLimit(1).help(job.name)
                    Text("→ "+job.settings.destinations.map{$0.lastPathComponent}.joined(separator:" / "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Label(presentation.title,systemImage:job.state == .verified && presentation.fraction==1 ? "checkmark.circle.fill":"circle.fill")
                            .font(.caption.bold()).foregroundStyle(presentation.tone.color).lineLimit(1)
                        Spacer(minLength:4)
                        Text("\(presentation.percent)%").font(.caption.bold()).monospacedDigit()
                    }
                    QueueProgressBar(value:presentation.fraction,color:presentation.tone.color)
                    if presentation.showsMetrics,let worker=job.engine {
                        Text(ByteCountFormatter.string(fromByteCount:Int64(max(0,worker.speedBytesPerSecond)),countStyle:.file)+"/s · "+eta(worker.overallEtaSeconds))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(job.state == .queued ? "Pending…":job.state == .verified && presentation.fraction==1 ? "Checksum verified":"Not fully verified")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
                if job.state == .running {
                    Button {if job.engine?.isPaused == true {queue.resumeActive()} else {queue.pauseActive()}} label:{Image(systemName:job.engine?.isPaused == true ? "play.fill":"pause.fill")}
                        .help(job.engine?.isPaused == true ? "Resume":"Pause")
                }
                Menu {actions} label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:22)
            }
            if job.state == .running,let worker=job.engine,!worker.currentFile.isEmpty {
                Text(worker.currentFile).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(worker.currentFile)
            }
            if let message=job.error ?? job.engine?.errorMessage {
                Label(message,systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let worker=job.engine,worker.destinationProgress.count>1 {
                DisclosureGroup("Destinations (\(worker.destinationProgress.count))") {
                    ForEach(worker.destinationProgress) {destination in
                        HStack {
                            Image(systemName:destination.verified ? "checkmark.circle.fill":"externaldrive")
                                .foregroundStyle(destination.verified ? Color.green:Color.secondary)
                            Text(destination.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(destination.state).font(.caption).lineLimit(1)
                            if let report=destination.report {Button("Log"){queue.draft.reveal(report)}}
                        }
                    }
                }.font(.caption)
            }
        }.padding(12).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
         .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(Color.white.opacity(0.06)))
    }
    @ViewBuilder private var actions:some View {
        if let worker=job.engine {Button("Transfer details…"){onDetails(worker)}}
        if job.state == .queued {
            Button("Move up"){queue.moveWaitingJob(job.id,earlier:true)}
            Button("Move down"){queue.moveWaitingJob(job.id,earlier:false)}
            Button("Remove waiting job"){queue.removeJob(job.id)}
        }
        if job.state == .running || job.state == .queued {Button("Cancel job",role:.destructive){queue.cancelJob(job.id)}}
        if job.state == .failed || job.state == .cancelled {Button("Retry failed job"){queue.retryJob(job.id)}}
        ForEach(Array(job.reportURLs.enumerated()),id:\.offset) {index,url in
            Button("Open TXT report \(index+1)"){queue.draft.reveal(url)}
        }
        if job.state.isTerminal {Button("Remove from list"){queue.removeJob(job.id)}}
    }
    private func eta(_ seconds:Double)->String {
        guard seconds.isFinite,seconds>0 else{return "Calculating…"}
        if seconds<1 {return "<1s remaining"}
        let formatter=DateComponentsFormatter();formatter.allowedUnits=seconds>=3600 ? [.hour,.minute]:[.minute,.second];formatter.unitsStyle = .abbreviated
        return (formatter.string(from:seconds) ?? "—")+" remaining"
    }
}
