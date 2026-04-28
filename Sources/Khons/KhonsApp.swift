import AppKit
import SwiftUI

@main
struct KhonsApp: App {
    init() {
        if let iconURL = Bundle.main.url(forResource: "Icon", withExtension: "png"),
           let image = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = image
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1180, height: 760)
    }
}
