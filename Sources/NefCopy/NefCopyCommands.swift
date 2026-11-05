import SwiftUI

// Route menu commands to the focused window, including preflight/modal guards.
struct NefCopyMenuActions {
    let canConfigure:Bool
    let canUseTools:Bool
    let canShowResults:Bool
    let canCancel:Bool
    let canClearSources:Bool
    let canClearDestinations:Bool
    let canEjectSources:Bool
    let canEjectDestinations:Bool
    let canEjectAll:Bool
    let clearSources:()->Void
    let clearDestinations:()->Void
    let clearAll:()->Void
    let ejectSources:()->Void
    let ejectDestinations:()->Void
    let ejectAll:()->Void
    let settings:()->Void
    let verify:()->Void
    let rename:()->Void
    let transfer:()->Void
    let retry:()->Void
    let results:()->Void
    let cancel:()->Void
}
private struct NefCopyActionsKey:FocusedValueKey {
    typealias Value=NefCopyMenuActions
}
extension FocusedValues {
    var nefCopyActions:NefCopyMenuActions? {
        get {self[NefCopyActionsKey.self]}
        set {self[NefCopyActionsKey.self]=newValue}
    }
}
struct NefCopyCommands:Commands {
    @FocusedValue(\.nefCopyActions) private var actions
    var body:some Commands {
        CommandGroup(replacing:.appSettings) {
            Button("Settings…") {actions?.settings()}
                .keyboardShortcut(",",modifiers:.command)
                .disabled(actions?.canConfigure != true)
        }
        CommandMenu("Disks") {
            Button("Eject all Source Disks…") {actions?.ejectSources()}.disabled(actions?.canEjectSources != true)
            Button("Eject all Destination Disks…") {actions?.ejectDestinations()}.disabled(actions?.canEjectDestinations != true)
            Divider()
            Button("Eject all Disks…") {actions?.ejectAll()}.disabled(actions?.canEjectAll != true)
            Divider()
            Button("Clear Sources and Destinations") {actions?.clearAll()}
                .keyboardShortcut("r",modifiers:[.command,.shift])
                .disabled(actions?.canClearSources != true && actions?.canClearDestinations != true)
            Button("Clear Sources") {actions?.clearSources()}
                .keyboardShortcut("s",modifiers:[.command,.shift])
                .disabled(actions?.canClearSources != true)
            Button("Clear Destinations") {actions?.clearDestinations()}
                .keyboardShortcut("d",modifiers:[.command,.shift])
                .disabled(actions?.canClearDestinations != true)
        }
        CommandMenu("Tools") {
            Menu("ASC MHL") {
                Button("Verify ASC MHL…") {actions?.verify()}.disabled(actions?.canUseTools != true)
                Button("Record file rename…") {actions?.rename()}.disabled(actions?.canUseTools != true)
                Button("Record cross-history move…") {actions?.transfer()}.disabled(actions?.canUseTools != true)
                Button("Retry pending transfer…") {actions?.retry()}.disabled(actions?.canUseTools != true)
                Divider()
                Button("Show results…") {actions?.results()}.disabled(actions?.canShowResults != true)
                Button("Cancel verification") {actions?.cancel()}.disabled(actions?.canCancel != true)
            }
        }
    }
}
