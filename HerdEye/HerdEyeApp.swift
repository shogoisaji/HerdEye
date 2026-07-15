import SwiftUI

/// HerdEye — a minimal app that displays agent status as a 3x3 dot grid in the menu bar.
/// LSUIElement: hidden from the Dock and has no window.
@main
@MainActor
struct HerdEyeApp: App {
    @NSApplicationDelegateAdaptor(BarAppDelegate.self) private var appDelegate

    var body: some Scene {
        // LSUIElement apps have no window. Launch NSApplication with an empty Settings scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class BarAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusBarController()
        controller.start()
    }
}
