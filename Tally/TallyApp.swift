import SwiftUI

@main
struct TallyApp: App {
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

        Window("Usage History", id: TallyWindow.history) {
            UsageHistoryView(store: store)
        }
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsRoot(store: store)
        }
    }
}
