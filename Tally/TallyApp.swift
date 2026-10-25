import AppKit
import SwiftUI

@MainActor
enum SetupLinks {
    static var pending: URL?
    static var handler: ((URL) -> Void)?
    private static var lastReceived: (url: String, at: Date)?

    static func receive(_ url: URL) {
        guard url.scheme?.lowercased() == "tally" else { return }
        let key = url.absoluteString
        if let lastReceived, lastReceived.url == key, Date().timeIntervalSince(lastReceived.at) < 1.5 {
            return
        }
        lastReceived = (key, Date())
        if let handler {
            handler(url)
        } else {
            pending = url
        }
    }

    static func install(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        if let pending {
            self.pending = nil
            handler(pending)
        }
    }
}

@MainActor
final class TallyAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            SetupLinks.receive(url)
        }
    }
}

@main
struct TallyApp: App {
    @NSApplicationDelegateAdaptor(TallyAppDelegate.self) private var appDelegate
    @State private var store = TallyStore()

    init() {
        BudgetNotifications.install()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        .handlesExternalEvents(matching: [])

        Window("Usage History", id: TallyWindow.history) {
            UsageHistoryView(store: store)
        }
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])

        Window("Connect to gateway", id: TallyWindow.connect) {
            ConnectView(store: store)
                .onOpenURL { SetupLinks.receive($0) }
        }
        .defaultSize(width: 360, height: 640)
        .handlesExternalEvents(matching: ["connect", "callback"])

        Settings {
            SettingsRoot(store: store)
        }
        .handlesExternalEvents(matching: [])
    }
}
