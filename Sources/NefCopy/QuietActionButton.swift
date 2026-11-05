import SwiftUI
import AppKit

// Native NSButton retains keyboard/VoiceOver actions without a blue focus ring.
struct QuietActionButton:NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    let title:String
    var systemImage:String?
    var bordered=true
    var escapeKey=false
    let action:()->Void
    init(_ title:String,systemImage:String?=nil,bordered:Bool=true,escapeKey:Bool=false,action:@escaping()->Void) {
        self.title=title;self.systemImage=systemImage;self.bordered=bordered;self.escapeKey=escapeKey;self.action=action
    }
    func makeCoordinator()->Coordinator {Coordinator(action)}
    func makeNSView(context:Context)->NSButton {
        let button=NSButton(title:title,target:context.coordinator,action:#selector(Coordinator.run))
        button.bezelStyle = .rounded;button.focusRingType = .none
        return button
    }
    func updateNSView(_ button:NSButton,context:Context) {
        context.coordinator.action=action;button.title=title;button.isEnabled=enabled
        button.isBordered=bordered;button.focusRingType = .none
        button.appearance=NSAppearance(named:colorScheme == .dark ? .darkAqua:.aqua)
        button.font=NSFont.systemFont(ofSize:13)
        button.contentTintColor = .labelColor
        button.image=systemImage.flatMap{NSImage(systemSymbolName:$0,accessibilityDescription:nil)}
        button.imagePosition=title.isEmpty ? .imageOnly:.imageLeft
        button.keyEquivalent=escapeKey ? "\u{1b}":"";button.keyEquivalentModifierMask=[]
        button.setAccessibilityLabel(title.isEmpty ? (systemImage=="gearshape" ? "Settings":"Button"):title)
        button.sizeToFit()
        button.cell?.focusRingType = .none
        button.focusRingType = .none
    }
    final class Coordinator:NSObject {
        var action:()->Void
        init(_ action:@escaping()->Void){self.action=action}
        @objc func run(){action()}
    }
}

