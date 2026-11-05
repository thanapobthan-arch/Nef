import SwiftUI
import AppKit

@main
struct NefCopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var queue = TransferQueue()

    var body: some Scene {
        WindowGroup {
            ContentView(queue:queue).preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 820, height: 780)
        .commands { NefCopyCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
