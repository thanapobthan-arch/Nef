import SwiftUI
import AppKit

// Fit structural content changes until the user manually resizes the window.
struct AdaptiveQueueWindow:NSViewRepresentable {
    let idealHeight:CGFloat
    func makeNSView(context:Context)->SizingView {SizingView()}
    func updateNSView(_ view:SizingView,context:Context) {
        view.idealHeight=idealHeight
        DispatchQueue.main.async {view.fitIfAutomatic()}
    }
    final class SizingView:NSView {
        var idealHeight:CGFloat=720
        private var appliedSize:NSSize?
        private var userResized=false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async {self.fitIfAutomatic()}
        }
        func fitIfAutomatic() {
            guard let window,let content=window.contentView,!window.inLiveResize,!userResized else{return}
            let current=content.bounds.size
            guard current.width>=600 else{return}
            if let appliedSize,abs(current.width-appliedSize.width)>2 || abs(current.height-appliedSize.height)>2 {
                userResized=true;return
            }
            let maximum=(window.screen?.visibleFrame.height ?? 1000)-65
            let desired=NSSize(width:current.width,height:max(560,min(idealHeight,maximum)))
            appliedSize=desired
            guard abs(current.height-desired.height)>2 else{return}
            var frame=window.frameRect(forContentRect:NSRect(origin:.zero,size:desired))
            frame.origin=NSPoint(x:window.frame.minX,y:window.frame.maxY-frame.height)
            window.setFrame(frame,display:true,animate:false)
        }
    }
}
