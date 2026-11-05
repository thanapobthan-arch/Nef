import SwiftUI

struct TransferHistoryView:View {
    @ObservedObject var queue:TransferQueue
    let onClose:()->Void
    @State private var historyError:String?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("NefCopy Transfer History").font(.title2.bold());Spacer()
                QuietActionButton("Close",escapeKey:true){onClose()}.fixedSize()
            }
            if queue.draft.history.isEmpty {
                Spacer();Text("No transfer history yet").foregroundStyle(.secondary);Spacer()
            } else {
                List(queue.draft.history) {record in
                    VStack(alignment:.leading,spacing:7) {
                        HStack {
                            Text(record.date.formatted(date:.abbreviated,time:.shortened)).font(.headline)
                            Spacer();Text(record.status).font(.caption.bold())
                        }
                        Text(record.sources.map{URL(fileURLWithPath:$0).lastPathComponent}.joined(separator:" / ")+" → "+record.destinations.map{URL(fileURLWithPath:$0).lastPathComponent}.joined(separator:" / "))
                            .font(.callout.bold()).textSelection(.enabled)
                        Text("Sources: "+record.sources.joined(separator:"\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Destinations: "+record.destinations.joined(separator:"\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("\(record.files) files · \(ByteCountFormatter.string(fromByteCount:record.bytes,countStyle:.file))").font(.caption)
                        if let path=record.reportPath {Button("Open TXT Log"){queue.draft.reveal(URL(fileURLWithPath:path))}}
                    }.padding(.vertical,5)
                }
            }
            if let historyError {Text(historyError).font(.caption).foregroundStyle(.red)}
            HStack {
                Text("Clearing history keeps copied files and TXT reports.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                QuietActionButton("Clear History") {
                    do {try queue.clearTransferHistory();historyError=nil}
                    catch {historyError=error.localizedDescription}
                }.fixedSize().disabled(queue.draft.history.isEmpty || !queue.canClearTransferHistory)
            }
        }.padding(24).frame(width:760,height:520).background(Color(red:0.12,green:0.12,blue:0.14)).modifier(NoBlueFocus())
    }

}
