import AppKit
import SwiftUI

struct PopoverRoot: View {
    @Bindable var store: TallyStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if store.gatewayEnabled {
                switch store.phase {
                case .signedOut:
                    SignInView(store: store)
                case .loading:
                    LoadingUsageView()
                case .failed:
                    FailedUsageView(store: store)
                case .empty:
                    EmptyUsageView(store: store)
                case .live:
                    livePopover
                }
            } else {
                CompactPopover(store: store, openHistory: openHistory, openSettings: showSettings)
            }
        }
        .preferredColorScheme(store.appearance.colorScheme)
        .onAppear {
            if store.phase == .live, store.layout == .compact, store.shouldPresentAlert {
                store.layout = .alert
            }
        }
    }

    @ViewBuilder
    private var livePopover: some View {
        switch store.layout {
        case .compact:
            CompactPopover(store: store, openHistory: openHistory, openSettings: showSettings)
        case .alert:
            AlertPopover(store: store, openHistory: openHistory, openSettings: showSettings)
        case .detailed:
            DetailedPopover(store: store, openHistory: openHistory, openSettings: showSettings)
        }
    }

    private func openHistory() {
        NSApp.activate()
        openWindow(id: TallyWindow.history)
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}
