import AppKit
import SwiftUI

final class KhonsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "Icon", withExtension: "png"),
           let image = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = image
        }
    }
}

@main
struct KhonsApp: App {
    @NSApplicationDelegateAdaptor(KhonsAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1180, height: 760)
    }
}
