import SwiftUI
struct NoBlueFocus:ViewModifier {
    @ViewBuilder func body(content:Content)->some View {
        if #available(macOS 14.0,*) {content.focusEffectDisabled()}
        else {content}
    }
}
