import SwiftUI

// Determinate fill renders directly from verified presentation state, including
// inactive windows and offscreen snapshots; accessibility retains the value.
struct QueueProgressBar:View {
    let value:Double
    var color:Color = .blue
    private var bounded:Double {value.isFinite ? min(max(value,0),1):0}
    var body:some View {
        GeometryReader {geometry in
            ZStack(alignment:.leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(color).frame(width:geometry.size.width*bounded)
            }
        }.frame(height:6)
         .accessibilityElement().accessibilityLabel("Progress")
         .accessibilityValue("\(Int((bounded*100).rounded(.down))) percent")
    }
}
