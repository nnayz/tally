import SwiftUI

struct PopoverRoot: View {
    @Bindable var store: TallyStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            switch store.phase {
            case .signedOut:
                SignInView(store: store)
            case .loading:
                LoadingView()
            case .offline:
                OfflineView(store: store)
            case .empty:
                EmptyUsageView(store: store)
            case .live:
                switch store.layout {
                case .compact:
                    CompactPopover(store: store, openHistory: openHistory, openSettings: showSettings)
                case .alert:
                    AlertPopover(store: store, openHistory: openHistory, openSettings: showSettings)
                case .detailed:
                    DetailedPopover(store: store, openHistory: openHistory, openSettings: showSettings)
                }
            }
        }
        .preferredColorScheme(store.appearance.colorScheme)
        .onAppear {
            if store.phase == .live, store.layout == .compact, store.shouldPresentAlert {
                store.layout = .alert
            }
        }
    }

    private func openHistory() {
        AppWindows.activate()
        openWindow(id: TallyWindow.history)
    }

    private func showSettings() {
        AppWindows.activate()
        openSettings()
    }
}
